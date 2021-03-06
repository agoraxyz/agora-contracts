// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import "./token/IAgoraToken.sol";
import "./AgoraSpace_utils/RankManager.sol";

/// @title A contract for staking tokens
contract AgoraSpace is RankManager {
    // Tokens managed by the contract
    address public immutable token;
    address public immutable stakeToken;

    // For timelock
    mapping(address => LockedItem[]) internal timelocks;

    struct LockedItem {
        uint256 expires;
        uint256 amount;
        uint256 rankId;
    }

    // For storing balances
    struct Balance {
        uint256 locked;
        uint256 unlocked;
    }

    mapping(uint256 => mapping(address => Balance)) public rankBalances;

    event Deposit(address indexed wallet, uint256 amount);
    event Withdraw(address indexed wallet, uint256 amount);
    event EmergencyWithdraw(address indexed wallet, uint256 amount);

    error InsufficientBalance(uint256 rankId, uint256 available, uint256 required);
    error TooManyDeposits();
    error NonPositiveAmount();

    /// @param _tokenAddress The address of the token to be staked, that the contract accepts
    /// @param _stakeTokenAddress The address of the token that's given in return
    constructor(address _tokenAddress, address _stakeTokenAddress) {
        token = _tokenAddress;
        stakeToken = _stakeTokenAddress;
    }

    /// @notice Accepts tokens, locks them and gives different tokens in return
    /// @dev The depositor should approve the contract to manage stakingTokens
    /// @dev For minting stakeTokens, this contract should be the owner of them
    /// @param _amount The amount to be deposited in the smallest unit of the token
    /// @param _rankId The id of the rank to be deposited to
    /// @param _consolidate Calls the consolidate function if true
    function deposit(
        uint256 _amount,
        uint256 _rankId,
        bool _consolidate
    ) external notFrozen {
        if (_amount < 1) revert NonPositiveAmount();
        if (timelocks[msg.sender].length >= 64) revert TooManyDeposits();
        if (numOfRanks < 1) revert NoRanks();
        if (_rankId >= numOfRanks) revert InvalidRank();
        if (
            rankBalances[_rankId][msg.sender].unlocked + rankBalances[_rankId][msg.sender].locked + _amount >=
            ranks[_rankId].goalAmount
        ) {
            unlockBelow(_rankId, msg.sender);
        } else if (_consolidate && _rankId > 0) {
            consolidate(_amount, _rankId, msg.sender);
        }
        LockedItem memory timelockData;
        timelockData.expires = block.timestamp + ranks[_rankId].minDuration * 1 minutes;
        timelockData.amount = _amount;
        timelockData.rankId = _rankId;
        timelocks[msg.sender].push(timelockData);
        rankBalances[_rankId][msg.sender].locked += _amount;
        IAgoraToken(stakeToken).mint(msg.sender, _amount);
        IERC20(token).transferFrom(msg.sender, address(this), _amount);
        emit Deposit(msg.sender, _amount);
    }

    /// @notice If the timelock is expired, gives back the staked tokens in return for the tokens obtained while depositing
    /// @dev This contract should have sufficient allowance to be able to burn stakeTokens from the user
    /// @dev For burning stakeTokens, this contract should be the owner of them
    /// @param _amount The amount to be withdrawn in the smallest unit of the token
    /// @param _rankId The id of the rank to be withdrawn from
    function withdraw(uint256 _amount, uint256 _rankId) external notFrozen {
        if (_amount < 1) revert NonPositiveAmount();
        uint256 expired = viewExpired(msg.sender, _rankId);
        if (rankBalances[_rankId][msg.sender].unlocked + expired < _amount)
            revert InsufficientBalance({
                rankId: _rankId,
                available: rankBalances[_rankId][msg.sender].unlocked + expired,
                required: _amount
            });
        unlockExpired(msg.sender);
        rankBalances[_rankId][msg.sender].unlocked -= _amount;
        IAgoraToken(stakeToken).burn(msg.sender, _amount);
        IERC20(token).transfer(msg.sender, _amount);
        emit Withdraw(msg.sender, _amount);
    }

    /// @notice Checks the locked tokens for an account and unlocks them if they're expired
    /// @param _investor The address whose tokens should be checked
    function unlockExpired(address _investor) public {
        uint256[] memory expired = new uint256[](numOfRanks);
        LockedItem[] storage usersLocked = timelocks[_investor];
        int256 usersLockedLength = int256(usersLocked.length);
        for (int256 i = 0; i < usersLockedLength; i++) {
            if (usersLocked[uint256(i)].expires <= block.timestamp) {
                // Collect expired amounts per ranks
                expired[usersLocked[uint256(i)].rankId] += usersLocked[uint256(i)].amount;
                // Remove expired locks
                usersLocked[uint256(i)] = usersLocked[uint256(usersLockedLength) - 1];
                usersLocked.pop();
                usersLockedLength--;
                i--;
            }
        }
        // Move expired amounts from locked to unlocked
        for (uint256 i = 0; i < numOfRanks; i++) {
            if (expired[i] > 0) {
                rankBalances[i][_investor].locked -= expired[i];
                rankBalances[i][_investor].unlocked += expired[i];
            }
        }
    }

    /// @notice Unlocks every deposit below a certain rank
    /// @dev Should be called, when the minimum of a rank is reached
    /// @param _investor The address whose tokens should be checked
    /// @param _rankId The id of the rank to be checked
    function unlockBelow(uint256 _rankId, address _investor) internal {
        LockedItem[] storage usersLocked = timelocks[_investor];
        int256 usersLockedLength = int256(usersLocked.length);
        uint256[] memory unlocked = new uint256[](numOfRanks);
        for (int256 i = 0; i < usersLockedLength; i++) {
            if (usersLocked[uint256(i)].rankId < _rankId) {
                // Collect the amount to be unlocked per rank
                unlocked[usersLocked[uint256(i)].rankId] += usersLocked[uint256(i)].amount;
                // Remove expired locks
                usersLocked[uint256(i)] = usersLocked[uint256(usersLockedLength) - 1];
                usersLocked.pop();
                usersLockedLength--;
                i--;
            }
        }
        // Move unlocked amounts from locked to unlocked
        for (uint256 i = 0; i < numOfRanks; i++) {
            if (unlocked[i] > 0) {
                rankBalances[i][_investor].locked -= unlocked[i];
                rankBalances[i][_investor].unlocked += unlocked[i];
            }
        }
    }

    /// @notice Collects the investments up to a certain rank if it's needed to reach the minimum
    /// @dev There must be more than 1 rank
    /// @dev The minimum should not be reached with the new deposit
    /// @dev The deposited amount must be locked after the function call
    /// @param _amount The amount to be deposited
    /// @param _rankId The id of the rank to be deposited to
    /// @param _investor The address which made the deposit
    function consolidate(
        uint256 _amount,
        uint256 _rankId,
        address _investor
    ) internal {
        uint256 consolidateAmount = ranks[_rankId].goalAmount -
            rankBalances[_rankId][_investor].unlocked -
            rankBalances[_rankId][_investor].locked -
            _amount;
        uint256 totalBalanceBelow;
        uint256 lockedBalance;
        uint256 unlockedBalance;

        LockedItem[] storage usersLocked = timelocks[_investor];
        int256 usersLockedLength = int256(usersLocked.length);

        for (uint256 i = 0; i < _rankId; i++) {
            lockedBalance = rankBalances[i][_investor].locked;
            unlockedBalance = rankBalances[i][_investor].unlocked;

            if (lockedBalance > 0) {
                totalBalanceBelow += lockedBalance;
                rankBalances[i][_investor].locked = 0;
            }

            if (unlockedBalance > 0) {
                totalBalanceBelow += unlockedBalance;
                rankBalances[i][_investor].unlocked = 0;
            }
        }

        if (totalBalanceBelow > 0) {
            LockedItem memory timelockData;
            // Iterate over the locked list and unlock everything below the rank
            for (int256 i = 0; i < usersLockedLength; i++) {
                if (usersLocked[uint256(i)].rankId < _rankId) {
                    usersLocked[uint256(i)] = usersLocked[uint256(usersLockedLength) - 1];
                    usersLocked.pop();
                    usersLockedLength--;
                    i--;
                }
            }
            // Create a new locked item and lock it for the rank's duration
            timelockData.expires = block.timestamp + ranks[_rankId].minDuration * 1 minutes;
            timelockData.rankId = _rankId;

            if (totalBalanceBelow > consolidateAmount) {
                // Set consolidateAmount as the locked amount
                timelockData.amount = consolidateAmount;
                rankBalances[_rankId][_investor].locked += consolidateAmount;
                rankBalances[_rankId][_investor].unlocked += totalBalanceBelow - consolidateAmount;
            } else {
                // Set totalBalanceBelow as the locked amount
                timelockData.amount = totalBalanceBelow;
                rankBalances[_rankId][_investor].locked += totalBalanceBelow;
            }
            timelocks[_investor].push(timelockData);
        }
    }

    /// @notice Gives back all the staked tokens in exchange for the tokens obtained, regardless of timelock
    /// @dev Can only be called when the contract is frozen
    function emergencyWithdraw() external {
        if (!frozen) revert SpaceIsNotFrozen();

        uint256 totalBalance;
        uint256 lockedBalance;
        uint256 unlockedBalance;

        for (uint256 i = 0; i < numOfRanks; i++) {
            lockedBalance = rankBalances[i][msg.sender].locked;
            unlockedBalance = rankBalances[i][msg.sender].unlocked;

            if (lockedBalance > 0) {
                totalBalance += lockedBalance;
                rankBalances[i][msg.sender].locked = 0;
            }

            if (unlockedBalance > 0) {
                totalBalance += unlockedBalance;
                rankBalances[i][msg.sender].unlocked = 0;
            }
        }
        if (totalBalance < 1) revert NonPositiveAmount();

        delete timelocks[msg.sender];
        IAgoraToken(stakeToken).burn(msg.sender, totalBalance);
        IERC20(token).transfer(msg.sender, totalBalance);
        emit EmergencyWithdraw(msg.sender, totalBalance);
    }

    /// @notice Returns all the timelocks a user has in an array
    /// @param _wallet The address of the user
    /// @return An array containing structs with fields "expires", "amount" and "rankId"
    function getTimelocks(address _wallet) external view returns (LockedItem[] memory) {
        return timelocks[_wallet];
    }

    /// @notice Sums the locked tokens for an account by ranks if they were expired
    /// @param _investor The address whose tokens should be checked
    /// @param _rankId The id of the rank to be checked
    /// @return The total amount of expired, but not unlocked tokens in the rank
    function viewExpired(address _investor, uint256 _rankId) public view returns (uint256) {
        uint256 expiredAmount;
        LockedItem[] memory usersLocked = timelocks[_investor];
        uint256 usersLockedLength = usersLocked.length;
        for (uint256 i = 0; i < usersLockedLength; i++) {
            if (usersLocked[i].rankId == _rankId && usersLocked[i].expires <= block.timestamp) {
                expiredAmount += usersLocked[i].amount;
            }
        }
        return expiredAmount;
    }
}
