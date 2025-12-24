#include "elfio/elfio.hpp"
#include "rocket-model.h"

#include <cassert>
#include <cstdint>
#include <functional>
#include <iostream>
#include <map>
#include <string>

#define TOHOST_ADDR 0x60000000
#define FROMHOST_ADDR 0x60000040
#define TOHOST_DATA_ADDR 0x60000080
#define TOHOST_DATA_SIZE 64 // bytes
#define SYS_write 64

RocketModel::~RocketModel() {}

static bool finished = false;

struct AxiPort {
  enum {
    RESP_OKAY = 0b00,
    RESP_EXOKAY = 0b01,
    RESP_SLVERR = 0b10,
    RESP_DECERR = 0b11
  };

  AxiInputs in;
  AxiOutputs out;

  void update_a();
  void update_b();

  std::function<void(size_t addr, size_t &data)> readFn;
  std::function<void(size_t addr, size_t data, size_t mask)> writeFn;

private:
  unsigned read_beats_left = 0;
  size_t read_id = 0;
  size_t read_addr = 0;
  size_t read_size = 0; // log2
  unsigned write_beats_left = 0;
  size_t write_id = 0;
  size_t write_addr = 0;
  size_t write_size = 0; // log2
  bool write_acked = true;
};

void AxiPort::update_a() {
  // Present read data.
  in.r_valid = false;
  in.r_id = 0;
  in.r_data = 0;
  in.r_resp = RESP_OKAY;
  in.r_last = false;
  if (read_beats_left > 0) {
    in.r_valid = true;
    in.r_id = read_id;
    if (readFn)
      readFn(read_addr, in.r_data);
    else
      in.r_data = 0x1050007310500073; // wfi
    in.r_last = read_beats_left == 1;
  }

  // Present write acknowledge.
  in.b_valid = false;
  in.b_id = 0;
  in.b_resp = RESP_OKAY;
  if (write_beats_left == 0 && !write_acked) {
    in.b_valid = true;
    in.b_id = write_id;
  }

  // Handle write data.
  in.w_ready = write_beats_left > 0;
  if (out.w_valid && in.w_ready) {
    if (writeFn) {
      size_t strb = out.w_strb;
      strb &= ((1 << (1 << write_size)) - 1) << (write_addr % 8);
      writeFn(write_addr, out.w_data, strb);
    }
    assert(out.w_last == (write_beats_left == 1));
    --write_beats_left;
    write_addr = ((write_addr >> write_size) + 1) << write_size;
  }

  // Handle read address.
  in.ar_ready = read_beats_left == 0;
  if (out.ar_valid && in.ar_ready) {
    read_beats_left = out.ar_len + 1;
    read_id = out.ar_id;
    read_addr = out.ar_addr;
    read_size = out.ar_size;
  }

  // Handle write address.
  in.aw_ready = write_beats_left == 0 && write_acked;
  if (out.aw_valid && in.aw_ready) {
    write_beats_left = out.aw_len + 1;
    write_id = out.aw_id;
    write_addr = out.aw_addr;
    write_size = out.aw_size;
    write_acked = false;
  }
}

void AxiPort::update_b() {
  if (in.r_valid && out.r_ready) {
    --read_beats_left;
    read_addr = ((read_addr >> read_size) + 1) << read_size;
  }

  if (in.b_valid && out.b_ready) {
    write_acked = true;
  }
}

static void tick(RocketModel &model, size_t cycle, bool trace) {
  if (trace)
    model.vcd_dump(cycle);
  model.set_clock(true);
  model.eval(true);
  model.set_clock(false);
  model.eval(false);
}

int main(int argc, char **argv) {
  const char *trace_file = nullptr;
  uint64_t trace_start = 0;
  uint64_t trace_cycles = 20000;
  uint64_t max_cycles = 1000000;
  const char *binary_path = nullptr;

  for (int i = 1; i < argc; ++i) {
    std::string arg = argv[i];
    if (arg == "--trace") {
      if (i + 1 >= argc) {
        std::cerr << "missing trace output file name after `--trace`\n";
        return 2;
      }
      trace_file = argv[++i];
      continue;
    }
    if (arg == "--trace-cycles") {
      if (i + 1 >= argc) {
        std::cerr << "missing value after `--trace-cycles`\n";
        return 2;
      }
      trace_cycles = std::stoull(argv[++i]);
      continue;
    }
    if (arg == "--trace-start") {
      if (i + 1 >= argc) {
        std::cerr << "missing value after `--trace-start`\n";
        return 2;
      }
      trace_start = std::stoull(argv[++i]);
      continue;
    }
    if (arg == "--max-cycles") {
      if (i + 1 >= argc) {
        std::cerr << "missing value after `--max-cycles`\n";
        return 2;
      }
      max_cycles = std::stoull(argv[++i]);
      continue;
    }
    if (!binary_path) {
      binary_path = argv[i];
      continue;
    }
    std::cerr << "usage: " << argv[0] << " [--trace <VCD>] [--trace-start N] [--trace-cycles N] [--max-cycles N] <binary>\n";
    return 2;
  }

  if (!binary_path) {
    std::cerr << "usage: " << argv[0] << " [--trace <VCD>] [--trace-start N] [--trace-cycles N] [--max-cycles N] <binary>\n";
    return 2;
  }

  // Read ELF into memory.
  std::map<uint64_t, uint64_t> memory;
  {
    ELFIO::elfio elf;
    if (!elf.load(binary_path)) {
      std::cerr << "unable to open file " << binary_path << "\n";
      return 2;
    }

    std::cerr << std::hex;
    for (const auto &segment : elf.segments) {
      if (segment->get_type() != ELFIO::PT_LOAD ||
          segment->get_memory_size() == 0)
        continue;
      std::cerr << "loading segment at " << segment->get_physical_address()
                << " (virtual address " << segment->get_virtual_address()
                << ")\n";
      for (unsigned i = 0; i < segment->get_memory_size(); ++i) {
        uint64_t addr = segment->get_physical_address() + i;
        uint8_t data = 0;
        if (i < segment->get_file_size())
          data = segment->get_data()[i];
        auto &slot = memory[addr / 8 * 8];
        slot &= ~((uint64_t)0xFF << ((addr % 8) * 8));
        slot |= (uint64_t)data << ((addr % 8) * 8);
      }
    }
    std::cerr << "entry " << elf.get_entry() << "\n";
    std::cerr << std::dec;
    std::cerr << "loaded " << memory.size() * 8 << " program bytes\n";
  }

  auto model = makeArcilatorModel();
  if (!model) {
    std::cerr << "unable to create arcilator model\n";
    return 2;
  }

  if (trace_file)
    model->vcd_start(trace_file);

  // Reset.
  size_t cycle = 0;
  for (unsigned i = 0; i < 1000; ++i) {
    model->set_reset(i < 100);
    bool trace = trace_file && cycle >= trace_start &&
                 cycle < trace_start + trace_cycles;
    tick(*model, cycle, trace);
    ++cycle;
  }

  AxiPort mem_port;
  mem_port.readFn = [&](size_t addr, size_t &data) {
    auto it = memory.find(addr / 8 * 8);
    if (it != memory.end())
      data = it->second;
    else
      data = 0x1050007310500073; // wfi
  };
  mem_port.writeFn = [&](size_t addr, size_t data, size_t mask) {
    assert(mask == 0xFF && "only full 64 bit write supported");
    memory[addr / 8 * 8] = data;
  };

  AxiPort mmio_port;
  mmio_port.writeFn = [&](size_t addr, size_t data, size_t mask) {
    assert(mask == 0xFF && "only full 64 bit write supported");
    memory[addr / 8 * 8] = data;

    // For a zero return code from the main function, 1 is written to tohost.
    if (addr == TOHOST_ADDR) {
      if (data == 1) {
        finished = true;
        return;
      }

      if (data == SYS_write) {
        for (int i = 0; i < TOHOST_DATA_SIZE; i += 8) {
          uint64_t data = memory[TOHOST_DATA_ADDR + i];
          unsigned char c[8];
          *(uint64_t *)c = data;
          for (int k = 0; k < 8; ++k) {
            if ((unsigned char)c[k] == 0)
              return;
            std::cout << c[k];
          }
        }
      }
    }
  };
  mmio_port.readFn = [&](size_t addr, size_t &data) {
    // Core loops on condition fromhost=0, thus set it to something non-zero.
    if (addr == FROMHOST_ADDR)
      data = (size_t)-1;
  };

  finished = false;
  for (uint64_t i = 0; i < max_cycles; ++i) {
    mem_port.out = model->get_mem();
    mem_port.update_a();
    model->set_mem(mem_port.in);

    mmio_port.out = model->get_mmio();
    mmio_port.update_a();
    model->set_mmio(mmio_port.in);

    model->eval();

    mem_port.out = model->get_mem();
    mem_port.update_b();
    model->set_mem(mem_port.in);

    mmio_port.out = model->get_mmio();
    mmio_port.update_b();
    model->set_mmio(mmio_port.in);

    bool trace = trace_file && cycle >= trace_start &&
                 cycle < trace_start + trace_cycles;
    tick(*model, cycle, trace);
    ++cycle;

    if (finished) {
      std::cout << "Benchmark run successful at cycle " << (cycle - 1) << "\n";
      return 0;
    }
  }

  std::cerr << "benchmark did not finish within " << max_cycles << " cycles\n";
  return 1;
}
