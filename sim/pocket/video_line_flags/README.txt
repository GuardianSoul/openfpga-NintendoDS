Decoded line-state experiment from exact6ef. Only video production source changes.
Three decoded flags plus modulo4 phase replace9bit retained line number.
Pad is unqualified at capture and uses current output layout combinationally.
Reference/oracles use ordinary ports. Current-layout-qualified pad capture would
be equivalent on reachable histories: layout changes only on line2 capture,
which simultaneously clears pad. The negative pad_input instead incorrectly
uses independently changeable layout_in and is a meaningful different fault.
No measured area benefit or board qualification claimed.
