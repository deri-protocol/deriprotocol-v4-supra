module deri::i256 {
    use std::string::{Self, String};
    use std::vector;
    use aptos_std::math64;
    use aptos_std::string_utils;

    const OVERFLOW: u64 = 0;

    const MIN_AS_U256: u256 = 1 << 255;
    const MAX_AS_U256: u256 = 0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

    const LT: u8 = 0;
    const EQ: u8 = 1;
    const GT: u8 = 2;

    struct I256 has copy, drop, store {
        bits: u256
    }

    public fun zero(): I256 {
        I256 { bits: 0 }
    }

    public fun from(v: u256): I256 {
        assert!(v <= MAX_AS_U256, OVERFLOW);
        I256 { bits: v }
    }

    public fun from_uncheck(v: u256): I256 {
        I256 { bits: v }
    }

    public fun neg_from(v: u256): I256 {
        assert!(v <= MIN_AS_U256, OVERFLOW);
        if (v == 0) {
            I256 { bits: v }
        } else {
            I256 {
                bits: (u256_neg(v) + 1) | (1 << 255)
            }
        }
    }

    public fun neg(v: I256): I256 {
        if (is_neg(v)) { abs(v) }
        else {
            neg_from(v.bits)
        }
    }

    public fun wrapping_add(num1: I256, num2: I256): I256 {
        let sum = num1.bits ^ num2.bits;
        let carry = (num1.bits & num2.bits) << 1;
        while (carry != 0) {
            let a = sum;
            let b = carry;
            sum = a ^ b;
            carry = (a & b) << 1;
        };
        I256 { bits: sum }
    }

    public fun add(num1: I256, num2: I256): I256 {
        let sum = wrapping_add(num1, num2);
        let overflow = (sign(num1) & sign(num2) & u8_neg(sign(sum)))
            + (u8_neg(sign(num1)) & u8_neg(sign(num2)) & sign(sum));
        assert!(overflow == 0, OVERFLOW);
        sum
    }

    public fun overflowing_add(num1: I256, num2: I256): (I256, bool) {
        let sum = wrapping_add(num1, num2);
        let overflow = (sign(num1) & sign(num2) & u8_neg(sign(sum)))
            + (u8_neg(sign(num1)) & u8_neg(sign(num2)) & sign(sum));
        (sum, overflow != 0)
    }

    public fun wrapping_sub(num1: I256, num2: I256): I256 {
        let sub_num = wrapping_add(I256 { bits: u256_neg(num2.bits) }, from(1));
        wrapping_add(num1, sub_num)
    }

    public fun sub(num1: I256, num2: I256): I256 {
        let sub_num = wrapping_add(I256 { bits: u256_neg(num2.bits) }, from(1));
        add(num1, sub_num)
    }

    public fun overflowing_sub(num1: I256, num2: I256): (I256, bool) {
        let sub_num = wrapping_add(I256 { bits: u256_neg(num2.bits) }, from(1));
        let sum = wrapping_add(num1, sub_num);
        let overflow =
            (sign(num1) & sign(sub_num) & u8_neg(sign(sum))) + (u8_neg(sign(num1)) & u8_neg(sign(sub_num))
                & sign(sum));
        (sum, overflow != 0)
    }

    public fun rescale(num: I256, decimals_s1: u8, decimals_s2: u8): I256 {
        if (decimals_s1 == decimals_s2) { num }
        else {
            let scaled =
                abs_u256(num) * (math64::pow(10, (decimals_s2 as u64)) as u256)
                    / (math64::pow(10, (decimals_s1 as u64)) as u256);
            if (is_neg(num)) {
                neg_from(scaled)
            } else {
                from(scaled)
            }
        }
    }

    public fun mul(num1: I256, num2: I256): I256 {
        let product = abs_u256(num1) * abs_u256(num2);
        if (sign(num1) != sign(num2)) {
            return neg_from(product)
        };
        return from(product)
    }

    public fun div(num1: I256, num2: I256): I256 {
        let result = abs_u256(num1) / abs_u256(num2);
        if (sign(num1) != sign(num2)) {
            return neg_from(result)
        };
        return from(result)
    }

    public fun abs(v: I256): I256 {
        if (sign(v) == 0) { v }
        else {
            assert!(v.bits > MIN_AS_U256, OVERFLOW);
            I256 { bits: u256_neg(v.bits - 1) }
        }
    }

    public fun abs_u256(v: I256): u256 {
        if (sign(v) == 0) { v.bits }
        else {
            u256_neg(v.bits - 1)
        }
    }

    public fun min(a: I256, b: I256): I256 {
        if (lt(a, b)) { a }
        else { b }
    }

    public fun max(a: I256, b: I256): I256 {
        if (gt(a, b)) { a }
        else { b }
    }

    public fun pow(base: I256, exponent: u64): I256 {
        let result = from(1);
        let b = base;
        let exp = exponent;

        while (exp > 0) {
            if (exp & 1 == 1) {
                result = mul(result, b);
            };
            b = mul(b, b);
            exp = exp >> 1;
        };
        result
    }

    public fun is_zero(v: I256): bool {
        v.bits == 0
    }

    public fun as_u256(v: I256): u256 {
        v.bits
    }

    public fun sign(v: I256): u8 {
        ((v.bits >> 255) as u8)
    }

    public fun is_neg(v: I256): bool {
        sign(v) == 1
    }

    public fun is_greater_than_zero(v: I256): bool {
        sign(v) == 0 && !is_zero(v)
    }

    public fun cmp(num1: I256, num2: I256): u8 {
        if (num1.bits == num2.bits) return EQ;
        if (sign(num1) > sign(num2)) return LT;
        if (sign(num1) < sign(num2)) return GT;
        if (num1.bits > num2.bits) {
            return GT
        } else {
            return LT
        }
    }

    public fun eq(num1: I256, num2: I256): bool {
        num1.bits == num2.bits
    }

    public fun gt(num1: I256, num2: I256): bool {
        cmp(num1, num2) == GT
    }

    public fun gte(num1: I256, num2: I256): bool {
        cmp(num1, num2) >= EQ
    }

    public fun lt(num1: I256, num2: I256): bool {
        cmp(num1, num2) == LT
    }

    public fun lte(num1: I256, num2: I256): bool {
        cmp(num1, num2) <= EQ
    }

    public fun or(num1: I256, num2: I256): I256 {
        I256 { bits: (num1.bits | num2.bits) }
    }

    public fun and(num1: I256, num2: I256): I256 {
        I256 { bits: (num1.bits & num2.bits) }
    }

    public fun to_string(self: I256): String {
        let s = string::utf8(b"");
        if (is_neg(self)) {
            string::append(&mut s, string::utf8(b"-"));
            string::append(&mut s, (u256_to_string(abs_u256(self))));
            s
        } else {
            string::append(&mut s, u256_to_string(as_u256(self)));
            s
        }
    }

    public fun u256_to_string(value: u256): String {
        string_utils::to_string(&value)
    }

    public fun string_to_u256(s: String): u256 {
        let num: u256 = 0;
        let len = (string::length(&s) as u256);
        let i = 0;

        while (i < len) {
            let bytes = *string::bytes(&s);
            let c = *vector::borrow(&bytes, (i as u64));
            let digit = char_to_digit(c);
            num = num * 10 + digit; // Shift left by one decimal place and add the new digit
            i = i + 1;
        };
        num
    }

    public fun lower_128_bits(v: u256): u256 {
        (v & ((1 << 128) - 1))
    }

    fun u256_neg(v: u256): u256 {
        v ^ 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
    }

    fun u8_neg(v: u8): u8 {
        v ^ 0xff
    }

    fun char_to_digit(c: u8): u256 {
        // Check if the character is between '0' and '9'
        if (c >= 48 && c <= 57) {
            (c as u256) - 48
        } else {
            abort 1 // Aborts if the character is not a valid decimal digit
        }
    }
}
