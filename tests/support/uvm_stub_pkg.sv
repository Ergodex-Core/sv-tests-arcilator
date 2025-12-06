// Minimal UVM stub package used for circt-verilog smoke testing.
// Provides just enough definitions and macros for the lightweight
// self-checking tests in this tree to elaborate.

package uvm_pkg;

  typedef int uvm_verbosity;
  localparam uvm_verbosity UVM_NONE = 0;
  localparam uvm_verbosity UVM_LOW  = 1;

  typedef class uvm_phase;

  class uvm_object;
    string m_name;
    function new(string name = "uvm_object");
      m_name = name;
    endfunction
    virtual function string get_type_name();
      return m_name;
    endfunction
    virtual function string get_full_name();
      return m_name;
    endfunction
  endclass

  class uvm_component extends uvm_object;
    uvm_component m_parent;
    function new(string name = "uvm_component", uvm_component parent = null);
      super.new(name);
      m_parent = parent;
    endfunction
    virtual function void build_phase(uvm_phase phase); endfunction
    virtual function void connect_phase(uvm_phase phase); endfunction
    virtual function void end_of_elaboration_phase(uvm_phase phase); endfunction
    virtual function void start_of_simulation_phase(uvm_phase phase); endfunction
    virtual task run_phase(uvm_phase phase); endtask
    virtual function void extract_phase(uvm_phase phase); endfunction
    virtual function void check_phase(uvm_phase phase); endfunction
    virtual function void report_phase(uvm_phase phase); endfunction
    virtual function string get_full_name();
      if (m_parent == null)
        return m_name;
      return {m_parent.get_full_name(), ".", m_name};
    endfunction
  endclass

  class uvm_sequence_item extends uvm_object;
    function new(string name = "uvm_sequence_item");
      super.new(name);
    endfunction
  endclass

  class uvm_phase;
    function void raise_objection(uvm_component comp); endfunction
    function void drop_objection(uvm_component comp); endfunction
  endclass

  class uvm_root extends uvm_component;
    static uvm_root m_inst;
    function new(string name = "uvm_root");
      super.new(name, null);
    endfunction
    static function uvm_root get();
      if (m_inst == null)
        m_inst = new("uvm_root");
      return m_inst;
    endfunction
  endclass

  class uvm_env extends uvm_component;
    function new(string name = "uvm_env", uvm_component parent = null);
      super.new(name, parent);
    endfunction
  endclass

  class uvm_agent extends uvm_component;
    function new(string name = "uvm_agent", uvm_component parent = null);
      super.new(name, parent);
    endfunction
  endclass

  class uvm_monitor extends uvm_component;
    function new(string name = "uvm_monitor", uvm_component parent = null);
      super.new(name, parent);
    endfunction
  endclass

  class uvm_scoreboard extends uvm_component;
    function new(string name = "uvm_scoreboard", uvm_component parent = null);
      super.new(name, parent);
    endfunction
  endclass
  class uvm_seq_item_pull_export #(type REQ = uvm_sequence_item);
    function new(string name = "uvm_seq_item_pull_export",
                 uvm_component parent = null);
    endfunction
  endclass

  class uvm_seq_item_pull_port #(type REQ = uvm_sequence_item);
    uvm_component m_parent;
    function new(string name = "uvm_seq_item_pull_port",
                 uvm_component parent = null);
      m_parent = parent;
    endfunction
    function void connect(uvm_seq_item_pull_export #(REQ) rhs);
    endfunction
    task get(output REQ item);
      item = new("seq_item_port_get");
    endtask
  endclass

  class uvm_sequencer #(type T = uvm_sequence_item) extends uvm_component;
    uvm_seq_item_pull_export #(T) seq_item_export;
    function new(string name = "uvm_sequencer", uvm_component parent = null);
      super.new(name, parent);
      seq_item_export = new("seq_item_export", this);
    endfunction
    virtual task start_item(T item); endtask
    virtual task finish_item(T item); endtask
  endclass

  class uvm_sequence #(type REQ = uvm_sequence_item,
                       type RSP = uvm_sequence_item) extends uvm_object;
    function new(string name = "uvm_sequence");
      super.new(name);
    endfunction
    virtual task pre_body(); endtask
    virtual task pre_do(bit is_item); endtask
    virtual function void mid_do(REQ this_item); endfunction
    virtual task body(); endtask
    virtual function void post_do(REQ this_item); endfunction
    virtual task post_body(); endtask
    virtual task start_item(REQ item); endtask
    virtual task finish_item(REQ item); endtask
    virtual task start(uvm_sequencer #(REQ) seqr); endtask
  endclass

  class uvm_test extends uvm_component;
    function new(string name = "uvm_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction
  endclass

  // Simple resource DB implementation backed by an associative array.
  class uvm_resource_db #(type T = int);
  typedef struct {
      string scope;
      string name;
      T value;
    } entry_t;
    static entry_t entries[$];

    static function void set(string scope, string name, T value);
      entries.push_back('{scope, name, value});
    endfunction

    static function bit read_by_name(string scope, string name, ref T value);
      foreach (entries[i]) begin
        if (entries[i].scope == scope && entries[i].name == name) begin
          value = entries[i].value;
          return 1;
        end
      end
      return 0;
    endfunction
  endclass

  class uvm_config_db #(type T = int);
    static function void set(uvm_component cntxt, string inst_name,
                             string field_name, T value);
      uvm_resource_db#(T)::set(inst_name, field_name, value);
    endfunction

    static function bit get(uvm_component cntxt, string inst_name,
                            string field_name, ref T value);
      return uvm_resource_db#(T)::read_by_name(inst_name, field_name, value);
    endfunction
  endclass

  class uvm_analysis_port #(type T = int);
    uvm_component m_parent;
    function new(string name = "uvm_analysis_port",
                 uvm_component parent = null);
      m_parent = parent;
    endfunction
    function void write(T t);
    endfunction
    function void connect(uvm_analysis_port #(T) rhs);
    endfunction
  endclass

  class uvm_driver #(type REQ = uvm_sequence_item,
                     type RSP = uvm_sequence_item) extends uvm_component;
    uvm_seq_item_pull_port #(REQ) seq_item_port;
    REQ req;
    function new(string name = "uvm_driver", uvm_component parent = null);
      super.new(name, parent);
      seq_item_port = new("seq_item_port", this);
    endfunction
    virtual task seq_item_port_get(output REQ item); endtask
  endclass

  task automatic run_test(string name = "");
  endtask

endpackage : uvm_pkg

`include "uvm_stub_macros.svh"
