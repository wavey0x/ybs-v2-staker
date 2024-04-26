pragma solidity ^0.8.0;

interface ICurve {
    // ERC20 functions
    function decimals() external view returns (uint8);
    function transfer(address _to, uint256 _value) external returns (bool);
    function transferFrom(address _from, address _to, uint256 _value) external returns (bool);
    function approve(address _spender, uint256 _value) external returns (bool);
    function permit(address _owner, address _spender, uint256 _value, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s) external returns (bool);

    // StableSwap functions
    function last_price() external view returns (uint256);
    function ema_price() external view returns (uint256);
    function get_balances() external view returns (uint256[2] memory);
    function admin_fee() external view returns (uint256);
    function A() external view returns (uint256);
    function A_precise() external view returns (uint256);
    function get_virtual_price() external view returns (uint256);
    function calc_token_amount(uint256[2] memory _amounts, bool _is_deposit) external view returns (uint256);
    function add_liquidity(uint256[2] memory _amounts, uint256 _min_mint_amount, address _receiver) external returns (uint256);
    function remove_liquidity(uint256 _burn_amount, uint256[2] memory _min_amounts, address _receiver) external returns (uint256[2] memory);
    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns (uint256);
    function coins(uint256) external view returns (address);
    function exchange(uint256 i, uint256 j, uint256 _dx, uint256 _min_dy, address _receiver) external returns (uint256);
    function exchange_underlying(uint256 i, uint256 j, uint256 _dx, uint256 _min_dy, address _receiver) external returns (uint256);
    function exchange_underlying(uint256 i, uint256 j, uint256 _dx, uint256 _min_dy) external returns (uint256);
    function remove_liquidity_one_coin(uint256 _burn_amount, int128 i, uint256 _min_received, address _receiver) external returns (uint256);
    function calc_withdraw_one_coin(uint256 _burn_amount, int128 i) external view returns (uint256);
    function ramp_A(uint256 _future_A, uint256 _future_time) external;
    function stop_ramp_A() external;
    function set_ma_exp_time(uint256 _ma_exp_time) external;
    function admin_balances(uint256 i) external view returns (uint256);
    function commit_new_fee(uint256 _new_fee) external;
    function apply_new_fee() external;
    function withdraw_admin_fees() external;
    function version() external pure returns (string memory);
}
