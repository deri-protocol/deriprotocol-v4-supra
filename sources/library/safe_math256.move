module deri::safe_math256 {
    use aptos_std::math64;

    public fun div_rounding_up(a: u256, b: u256): u256 {
        let c = a / b;
        if (b * c != a) {
            c = c + 1
        };
        c
    }

    public fun rescale(value: u256, decimals_s1: u8, decimals_s2: u8): u256 {
        if (decimals_s1 == decimals_s2) { value }
        else {
            value * (math64::pow(10, (decimals_s2 as u64)) as u256) / (math64::pow(10, (decimals_s1 as u64)) as u256)
        }
    }

    public fun rescale_down(value: u256, decimals_s1: u8, decimals_s2: u8): u256 {
        rescale(value, decimals_s1, decimals_s2)
    }

    /// Return the smallest of two numbers.
    public fun min(a: u256, b: u256): u256 {
        if (a < b) a else b
    }
}
