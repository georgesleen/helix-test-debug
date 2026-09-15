#include "divider.h"

// Lives under lib/ rather than src/, because PlatformIO leaves src/ out of a
// test build unless test_build_src is set, while lib/ is always linked.
int halve(int value) {
  return value / 2;
}
