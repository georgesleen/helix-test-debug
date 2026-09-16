// Fixture firmware for tests/hardware-check.sh. It runs on a real Pico 2,
// so it has to keep running after the breakpoint is hit: the check
// continues the core and looks at a variable.
//
// ticks is volatile and file-scope so it survives optimisation and is
// readable from the target as a static, whatever the build type.
#include "pico/stdlib.h"

static volatile unsigned ticks;

int main(void) {
    const uint led = PICO_DEFAULT_LED_PIN;
    gpio_init(led);
    gpio_set_dir(led, GPIO_OUT);

    while (true) {
        ticks += 1; // the line the check stops on
        gpio_put(led, ticks & 1u);
        sleep_ms(100);
    }
}
