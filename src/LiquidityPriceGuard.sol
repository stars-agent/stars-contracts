// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IV3Pool} from "./Interfaces.sol";
import {TickMath} from "./TickMath.sol";

/// @dev Stateless price checks for the Gateway. This contract never holds or approves project funds.
contract LiquidityPriceGuard {
    uint32 private constant TWAP_WINDOW = 30 minutes;
    int24 private constant QUOTE_TOLERANCE = 100;
    int24 private constant TWAP_TOLERANCE = 200;

    function launchFloor(uint160 initial, bool first) external pure returns (int24) {
        uint256 floorSqrt = first ? uint256(initial) * 9 / 10 : uint256(initial) * 10 / 9;
        return TickMath.getTickAtSqrtRatio(uint160(floorSqrt));
    }

    function check(IV3Pool p, bool first, int24 floor, uint160 quotedSqrtPrice)
        external
        returns (int24 lower, int24 upper, bool allowed, bool expanded)
    {
        (uint160 sqrt,,,,,,) = p.slot0();
        int24 tick = _edgeTick(sqrt, first);
        lower = first ? floor : tick;
        upper = first ? tick : floor;
        if (lower < upper && quotedSqrtPrice >= TickMath.MIN_SQRT_RATIO && quotedSqrtPrice < TickMath.MAX_SQRT_RATIO) {
            int24 referenceTick = _edgeTick(quotedSqrtPrice, first);
            if (tick >= referenceTick - QUOTE_TOLERANCE && tick <= referenceTick + QUOTE_TOLERANCE) {
                (allowed, expanded) = _twapAllows(p, tick);
            }
        }
    }

    function _edgeTick(uint160 sqrt, bool tokenFirst) private pure returns (int24 tick) {
        tick = TickMath.getTickAtSqrtRatio(sqrt);
        if (!tokenFirst && TickMath.getSqrtRatioAtTick(tick) < sqrt) ++tick;
    }

    function _twapAllows(IV3Pool p, int24 edge) private returns (bool allowed, bool expanded) {
        uint32[] memory ages = new uint32[](2);
        ages[0] = TWAP_WINDOW;
        try p.observe(ages) returns (int56[] memory sums, uint160[] memory) {
            int56 delta;
            unchecked {
                delta = sums[1] - sums[0]; // V3's int56 cumulative wraps.
            }
            int56 period = int56(uint56(TWAP_WINDOW));
            int56 mean = delta / period;
            if (delta < 0 && delta % period != 0) --mean;
            return (edge >= mean - TWAP_TOLERANCE && edge <= mean + TWAP_TOLERANCE, false);
        } catch {
            // A busy pool may overwrite its oldest observation. Grow in bounded steps.
            // V3 writes at most once per distinct second, so 1,801 slots suffice.
            (,,, uint16 size, uint16 next,,) = p.slot0();
            uint16 maximum = uint16(TWAP_WINDOW + 1);
            if (size == next && next < maximum) {
                uint16 target = next + 32;
                p.increaseObservationCardinalityNext(target < maximum ? target : maximum);
                return (false, true);
            }
            return (false, false);
        }
    }
}
