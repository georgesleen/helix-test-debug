// Fixture firmware for the embedded half of tests/integration.sh. Arduino
// entry points, because that is what the offline toolchain here provides.
// Its lines are stopped at by the check, so their numbering is part of it.
#include <Arduino.h>

#include "divider.h"

void setup() { Serial.begin(115200); }

void loop() {
  int halved = halve(84);
  Serial.println(halved);
  delay(1000);
}
