// Fixture binary for tests/integration.sh: the path where the cursor is not
// in a test, so the crate's own binary is what runs. Its lines are stopped
// at by the check, so their numbering is part of it.

fn main() {
    let value = fixture::inner::doubled(21);
    println!("doubled(21) = {value}");
}
