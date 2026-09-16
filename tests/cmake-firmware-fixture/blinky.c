// Fixture firmware. No runtime and no linker script: it only has to link
// and carry line information, since nothing here is ever executed.
int halve(int value);

int main(void) {
  volatile int ticks = 0;
  ticks += halve(84);
  for (;;) {
  }
  return ticks;
}
