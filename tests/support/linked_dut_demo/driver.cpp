#include "linked_dut_demo-arc.h"

#include <algorithm>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>

template <typename T>
static void set_field(T &field, uint64_t value) {
  const size_t n = std::min(sizeof(field), sizeof(value));
  std::memcpy(&field, &value, n);
}

template <typename T>
static uint64_t get_field(const T &field) {
  uint64_t value = 0;
  const size_t n = std::min(sizeof(field), sizeof(value));
  std::memcpy(&value, &field, n);
  return value;
}

int main() {
  const char *vcd_path = std::getenv("ARCILATOR_VCD_PATH");
  if (!vcd_path) {
    vcd_path = "wave.vcd";
  }

  top dut;

  std::ofstream vcd(vcd_path);
  if (!vcd) {
    std::cerr << "failed to open VCD output: " << vcd_path << "\n";
    return 1;
  }
  auto vcd_writer = dut.vcd(vcd);

  // Drive a value and ensure it shows up in the output.
  const uint8_t kIn = 0x2A;
  set_field(dut.view.in, kIn);

  set_field(dut.view.clk, 0);
  set_field(dut.view.rst, 0);
  dut.eval();
  vcd_writer.writeTimestep(1);

  const uint8_t out = static_cast<uint8_t>(get_field(dut.view.out));
  if (out != kIn) {
    std::cerr << "mismatch: out=" << static_cast<unsigned>(out)
              << " expected=" << static_cast<unsigned>(kIn) << "\n";
    return 1;
  }
  return 0;
}
