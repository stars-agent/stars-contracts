// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev One ledger per issuing token. Settle shares before changing a holder's weight.
abstract contract DividendLedger {
    using SafeERC20 for IERC20;

    uint256 private constant SCALE = 1e30;
    uint256 private constant RELEASE_ROUNDS = 12;

    struct DividendSchedule {
        uint8 nextSlot;
        uint8 roundsLeft;
        uint256[RELEASE_ROUNDS] installments;
    }

    struct Holder {
        uint256 shares;
        uint256 lastIndex;
        uint256 pending;
    }

    struct Ledger {
        uint256 totalShares;
        uint256 dividendPerShare;
        uint256 queuedDividends;
        address rewardAsset;
        mapping(address => Holder) holders;
    }
    mapping(address => Ledger) internal ledgers;

    event DividendFunded(address indexed token, address indexed asset, uint256 amount);
    event DividendClaimed(address indexed token, address indexed holder, uint256 amount);

    function totalShares(address token) external view returns (uint256) {
        return ledgers[token].totalShares;
    }

    function claimable(address token, address account) public view returns (uint256) {
        Ledger storage ledger = ledgers[token];
        Holder storage h = ledger.holders[account];
        return h.pending + Math.mulDiv(h.shares, ledger.dividendPerShare - h.lastIndex, SCALE);
    }

    function _setShares(address token, address account, uint256 next) internal {
        Ledger storage ledger = ledgers[token];
        Holder storage h = ledger.holders[account];
        if (h.shares == next) return;
        h.pending = claimable(token, account);
        ledger.totalShares = ledger.totalShares - h.shares + next;
        h.lastIndex = ledger.dividendPerShare;
        h.shares = next;
    }

    function _fundDividend(address token, uint256 amount, DividendSchedule storage schedule) internal {
        Ledger storage ledger = ledgers[token];
        emit DividendFunded(token, ledger.rewardAsset, amount);
        if (ledger.totalShares == 0) {
            ledger.queuedDividends += amount;
            return;
        }

        uint256 queued = ledger.queuedDividends;
        if (queued != 0) {
            uint256 share = queued / RELEASE_ROUNDS;
            uint256 extraFrom = RELEASE_ROUNDS - queued % RELEASE_ROUNDS;
            // Add new installments to the next twelve eligible distributions.
            // Existing installments keep their due dates when schedules overlap.
            for (uint256 i; i < RELEASE_ROUNDS; ++i) {
                uint256 slot = (schedule.nextSlot + i) % RELEASE_ROUNDS;
                schedule.installments[slot] += share + (i >= extraFrom ? 1 : 0);
            }
            ledger.queuedDividends = 0;
            schedule.roundsLeft = uint8(RELEASE_ROUNDS);
        }
        if (schedule.roundsLeft != 0) {
            uint256 slot = schedule.nextSlot;
            amount += schedule.installments[slot];
            delete schedule.installments[slot];
            schedule.nextSlot = uint8((slot + 1) % RELEASE_ROUNDS);
            --schedule.roundsLeft;
        }
        ledger.dividendPerShare += Math.mulDiv(amount, SCALE, ledger.totalShares);
    }

    function _claim(address token, address account) internal returns (uint256 amount) {
        Ledger storage ledger = ledgers[token];
        amount = claimable(token, account);
        require(amount != 0, "no dividends");
        ledger.holders[account].pending = 0;
        ledger.holders[account].lastIndex = ledger.dividendPerShare;
        IERC20 asset = IERC20(ledger.rewardAsset);
        uint256 beforeBalance = asset.balanceOf(address(this));
        asset.safeTransfer(account, amount);
        require(beforeBalance - asset.balanceOf(address(this)) == amount, "unexpected reward debit");
        emit DividendClaimed(token, account, amount);
    }
}
