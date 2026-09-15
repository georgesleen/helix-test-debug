// Fixture test folder for the cog's PlatformIO support. Its shape is part of
// the check: Unity marks nothing, so a test is only a test because main calls
// RUN_TEST on it. test_unregistered_is_never_run is here to be found and
// rejected, and test_halves is a prefix of test_halves_negative so a filter
// that is not exact drags the second one along.

#include <unity.h>

#include "divider.h"

static int calls;

void setUp(void) {
  calls = 0;
}

void tearDown(void) {
  calls = 0;
}

void test_halves(void) {
  calls++;
  TEST_ASSERT_EQUAL_INT(2, halve(4));
}

void test_halves_negative(void) {
  calls++;
  TEST_ASSERT_EQUAL_INT(-3, halve(-6));
}

void test_halves_odd_rounds_toward_zero(void) {
  calls++;
  TEST_ASSERT_EQUAL_INT(3, halve(7));
}

// No RUN_TEST names this one, so it must not count as a test.
void test_unregistered_is_never_run(void) {
  TEST_FAIL_MESSAGE("test_unregistered_is_never_run was registered");
}

int main(void) {
  UNITY_BEGIN();
  RUN_TEST(test_halves);
  RUN_TEST(test_halves_negative);
  RUN_TEST(test_halves_odd_rounds_toward_zero);
  return UNITY_END();
}
