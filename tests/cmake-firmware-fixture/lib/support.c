// Compiled into a static library rather than into the executable, which is
// the shape ESP-IDF puts a project's own main.c in: the image is reached
// from here only by following the link graph. The line numbering is part of
// tests/integration.sh.
int halve(int value) {
  volatile int half = value / 2; // the library line the check stops on
  return half;
}
