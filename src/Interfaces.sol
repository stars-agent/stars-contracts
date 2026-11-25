// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IHub {
    function owner() external view returns (address);
    function tradingPaused() external view returns (bool);
    function recordBalance(address from, address to, uint256 amount, uint256 fromBalance, uint256 toBalance) external;
    function recordTax(uint256 burned, uint256 accrued) external;
    function recordConversion(uint256 tokens, uint256 bnb) external;
}

interface IRegistry {
    function handleOf(address) external view returns (string memory);
    function ownerOf(uint256) external view returns (address);
}

interface IWBNB {
    function deposit() external payable;
    function withdraw(uint256) external;
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256);
}

interface IV3Pool {
    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory, uint160[] memory);
    function increaseObservationCardinalityNext(uint16 next) external;
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool);
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

interface IPositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }
    function createAndInitializePoolIfNecessary(address, address, uint24, uint160) external payable returns (address);
    function mint(MintParams calldata) external payable returns (uint256, uint128, uint256, uint256);
}
