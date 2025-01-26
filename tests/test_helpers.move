#[test_only]
module deri::test_helpers {

    use std::string;
    use aptos_std::debug::print;

    #[test]
    fun x() {
        print(&b"ETH^2");
        print(&string::utf8(x"4554485e32"))
    }
}
