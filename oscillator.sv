module OSC_TOP (
    clk
);
  output clk;
  OSCG OSCinst0 (.OSC(clk));
  // 2.4MHz
endmodule

(* blackbox *)
module OSCG #(
    parameter DIV = 128
) (
    output logic OSC
);
endmodule
