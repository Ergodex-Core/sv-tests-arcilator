// Minimal macro set for the UVM stub. Provides just enough logging and
// factory helpers for the lightweight smoke tests in this tree.

`ifndef UVM_STUB_MACROS_SVH
`define UVM_STUB_MACROS_SVH

`define uvm_info(ID, MSG, VERBOSITY) \
  $display("[UVM_INFO][%s] %s", ID, MSG);

`define uvm_error(ID, MSG) \
  $display("[UVM_ERROR][%s] %s", ID, MSG);

`define uvm_component_utils(TYPE) \
  class type_id; \
    static function TYPE create(string name = "", uvm_component parent = null); \
      return new(name, parent); \
    endfunction \
  endclass

`define uvm_object_utils(TYPE) \
  class type_id; \
    static function TYPE create(string name = "", uvm_component parent = null); \
      return new(name); \
    endfunction \
  endclass

`define uvm_object_utils_begin(TYPE) \
  `uvm_object_utils(TYPE)

`define uvm_object_utils_end

`define uvm_component_utils_begin(TYPE) \
  `uvm_component_utils(TYPE)

`define uvm_component_utils_end

`define uvm_field_int(FIELD, FLAGS)
`define uvm_field_enum(TYPE, FIELD, FLAGS)
`define uvm_field_object(FIELD, FLAGS)
`define uvm_field_queue(TYPE, FIELD, FLAGS)

`endif  // UVM_STUB_MACROS_SVH
