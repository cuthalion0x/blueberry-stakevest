// SPDX-License-Identifier: BUSL-1.1
/*
██████╗ ██╗     ██╗   ██╗███████╗██████╗ ███████╗██████╗ ██████╗ ██╗   ██╗
██╔══██╗██║     ██║   ██║██╔════╝██╔══██╗██╔════╝██╔══██╗██╔══██╗╚██╗ ██╔╝
██████╔╝██║     ██║   ██║█████╗  ██████╔╝█████╗  ██████╔╝██████╔╝ ╚████╔╝
██╔══██╗██║     ██║   ██║██╔══╝  ██╔══██╗██╔══╝  ██╔══██╗██╔══██╗  ╚██╔╝
██████╔╝███████╗╚██████╔╝███████╗██████╔╝███████╗██║  ██║██║  ██║   ██║
╚═════╝ ╚══════╝ ╚═════╝ ╚══════╝╚═════╝ ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝
*/

pragma solidity ^0.8.0;

import {PausableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/security/PausableUpgradeable.sol";
import {Ownable2StepUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";

import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-core/libraries/TickMath.sol";
import "v3-core/libraries/FullMath.sol";
import "v3-core/libraries/FixedPoint96.sol";

import {IBlueberryToken, IERC20} from "./interfaces/IBlueberryToken.sol";
import {IBlueberryStaking} from "./interfaces/IBlueberryStaking.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

/**
 * @title Blueberry's staking contract with vesting for bdblb distribution
 * @author Blueberry Protocol
 */
contract BlueberryStaking is
    IBlueberryStaking,
    Ownable2StepUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////
                        VARIABLES
    //////////////////////////////////////////////////*/

    /// @notice The Blueberry token contract
    IBlueberryToken public blb;

    /// @notice The  token contract
    /// @notice The stableAsset token contract
    IERC20 public stableAsset;

    /// @notice The treasury address
    address public treasury;

    /// @notice The Uniswap V3 pool address
    address public uniswapV3Pool;

    /// @notice The Uniswap V3 factory address
    address public uniswapV3Factory;

    /// @notice The observation period for Uniswap V3
    uint32 public observationPeriod;

    /// @notice The total number of iBtokens
    uint256 public totalIbTokens;

    /// @notice The total supply of tokens for each address
    mapping(address => uint256) public totalSupply;

    /// @notice The stored reward per token for each address
    mapping(address => uint256) public rewardPerTokenStored;

    /// @notice The last update time for each address
    mapping(address => uint256) public lastUpdateTime;

    /// @notice The reward rate for each address
    mapping(address => uint256) public rewardRate;

    /// @notice The last claimed epoch for each address
    mapping(address => uint256) public lastClaimedEpoch;

    /// @notice The ibtoken status for each address
    mapping(address => bool) public isIbToken;

    /// @notice The vesting schedule for each address
    mapping(address => Vest[]) public vesting;

    /// @notice The balance of tokens for each address
    mapping(address => mapping(address => uint256)) public balanceOf;

    /// @notice The rewards for each address
    mapping(address => mapping(address => uint256)) public rewards;

    /// @notice The paid reward per token for each user
    mapping(address => mapping(address => uint256))
        public userRewardPerTokenPaid;

    /// @notice The reward duration
    uint256 public rewardDuration;

    /// @notice The finish time for rewards
    uint256 public finishAt;

    /// @notice The length of the vesting period
    uint256 public vestLength;

    /// @notice The deployment time of the contract
    uint256 public deployedAt;

    // 25% at the start of each vesting period
    uint256 public basePenaltyRatioPercent;

    // Number of decimals for the stable asset
    uint256 private stableDecimals;

    mapping(uint256 => Epoch) public epochs;

    /**
     * @notice the length of an epoch in seconds
     * @dev 14 days by default
     */
    uint256 public epochLength;

    /**
     * @notice A list of all the ibTokens
     * @dev This storage variable was added on Jan 31, 2022 as part of an upgrade to improve user experience
     */
    address[] public ibTokens;

    /*//////////////////////////////////////////////////
                        CONSTRUCTOR
    //////////////////////////////////////////////////*/
    constructor() {}

    /*//////////////////////////////////////////////////
                     FUNCTIONS
    //////////////////////////////////////////////////*/

    /**
     * @notice The constructor function, called when the contract is deployed
     * @param _blb The token that will be used as rewards
     * @param _usdc The usdc token address
     * @param _treasury The treasury address
     * @param _rewardDuration The duration of the reward period
     * @param _ibTokens An array of the bTokens that can be staked
     */
    function initialize(
        address _blb,
        address _usdc,
        address _treasury,
        uint256 _rewardDuration,
        address[] memory _ibTokens,
        address _admin
    ) public initializer {
        __Ownable2Step_init();
        __Pausable_init();
        _transferOwnership(_admin);

        if (
            _blb == address(0) || _usdc == address(0) || _treasury == address(0)
        ) {
            revert AddressZero();
        }

        if (_ibTokens.length == 0) {
            revert InvalidIbToken();
        }

        for (uint256 i; i < _ibTokens.length; ++i) {
            if (_ibTokens[i] == address(0)) {
                revert AddressZero();
            }

            isIbToken[_ibTokens[i]] = true;
        }

        if (_rewardDuration == 0) {
            revert InvalidRewardDuration();
        }

        blb = IBlueberryToken(_blb);
        stableAsset = IERC20(_usdc);
        stableDecimals = 6;
        treasury = _treasury;
        totalIbTokens = _ibTokens.length;
        rewardDuration = _rewardDuration;
        vestLength = 52 weeks;
        basePenaltyRatioPercent = 0.25e18;
        epochLength = 1_209_600;
        uniswapV3Factory = address(0x1F98431c8aD98523631AE4a59f267346ea31F984);
        observationPeriod = 3600;
        finishAt = block.timestamp + _rewardDuration;
        deployedAt = block.timestamp;
    }

    /**
     * @notice updates the rewards for a given user and a given array of tokens
     * @param _user The user to update the rewards for
     * @param _ibTokens An array of tokens to update the rewards for
     */
    modifier updateRewards(address _user, address[] calldata _ibTokens) {
        for (uint256 i; i < _ibTokens.length; ++i) {
            address _ibToken = _ibTokens[i];

            _updateReward(_user, _ibToken);
        }
        _;
    }

    /// Contains the logic for updateReward function
    function _updateReward(address _user, address _ibToken) internal {
        if (!isIbToken[_ibToken]) {
            revert InvalidIbToken();
        }

        rewardPerTokenStored[_ibToken] = rewardPerToken(_ibToken);
        lastUpdateTime[_ibToken] = lastTimeRewardApplicable();

        if (_user != address(0)) {
            rewards[_user][_ibToken] = _earned(_user, _ibToken);
            userRewardPerTokenPaid[_user][_ibToken] = rewardPerTokenStored[
                _ibToken
            ];
        }
    }

    /// @inheritdoc IBlueberryStaking
    function stake(
        address[] calldata _ibTokens,
        uint256[] calldata _amounts
    ) external whenNotPaused updateRewards(msg.sender, _ibTokens) {
        if ((_amounts.length) != _ibTokens.length) {
            revert InvalidLength();
        }

        for (uint256 i; i < _ibTokens.length; ++i) {
            address _ibToken = _ibTokens[i];

            if (!isIbToken[_ibToken]) {
                revert InvalidIbToken();
            }

            uint256 _amount = _amounts[i];

            balanceOf[msg.sender][_ibToken] += _amount;
            totalSupply[_ibToken] += _amount;

            IERC20(_ibToken).safeTransferFrom(
                msg.sender,
                address(this),
                _amount
            );
        }

        emit Staked(msg.sender, _ibTokens, _amounts, block.timestamp);
    }

    /// @inheritdoc IBlueberryStaking
    function unstake(
        address[] calldata _ibTokens,
        uint256[] calldata _amounts
    ) external whenNotPaused updateRewards(msg.sender, _ibTokens) {
        if (_amounts.length != _ibTokens.length) {
            revert InvalidLength();
        }

        for (uint256 i; i < _ibTokens.length; ++i) {
            address _ibToken = _ibTokens[i];

            if (!isIbToken[address(_ibToken)]) {
                revert InvalidIbToken();
            }

            uint256 _amount = _amounts[i];

            balanceOf[msg.sender][address(_ibToken)] -= _amount;
            totalSupply[address(_ibToken)] -= _amount;

            IERC20(_ibToken).safeTransfer(msg.sender, _amount);
        }

        emit Unstaked(msg.sender, _ibTokens, _amounts, block.timestamp);
    }

    /*//////////////////////////////////////////////////
                     VESTING FUNCTIONS
    //////////////////////////////////////////////////*/

    modifier updateVests(address _user, uint256[] calldata _vestIndexes) {
        if (vesting[msg.sender].length < _vestIndexes.length) {
            revert InvalidLength();
        }

        Vest[] storage vests = vesting[msg.sender];

        for (uint256 i; i < _vestIndexes.length; ++i) {
            Vest storage vest = vests[_vestIndexes[i]];

            if (vest.amount == 0) {
                revert NothingToUpdate();
            }

            uint256 _vestEpoch = (vest.startTime - deployedAt) / epochLength;

            if (epochs[_vestEpoch].redistributedBLB > 0) {
                vest.amount =
                    (vest.amount * epochs[_vestEpoch].redistributedBLB) /
                    epochs[_vestEpoch].totalBLB;
            }
        }

        _;
    }

    /// @inheritdoc IBlueberryStaking
    function startVesting(
        address[] calldata _ibTokens
    ) external whenNotPaused updateRewards(msg.sender, _ibTokens) {
        if (!canClaim(msg.sender)) {
            revert AlreadyClaimed();
        }

        uint256 _currentEpoch = currentEpoch();

        lastClaimedEpoch[msg.sender] = _currentEpoch;

        uint256 totalRewards;
        for (uint256 i; i < _ibTokens.length; ++i) {
            if (!isIbToken[address(_ibTokens[i])]) {
                revert InvalidIbToken();
            }

            IERC20 _ibToken = IERC20(_ibTokens[i]);
            uint256 reward = rewards[msg.sender][address(_ibToken)];

            if (reward > 0) {
                totalRewards += reward;
                rewards[msg.sender][address(_ibToken)] = 0;

                // month 1: $0.02 / blb
                uint256 _priceUnderlying = getPrice();

                vesting[msg.sender].push(
                    Vest(reward, block.timestamp, _priceUnderlying)
                );
            }
        }

        epochs[_currentEpoch].totalBLB += totalRewards;

        emit Claimed(msg.sender, totalRewards, block.timestamp);
    }

    /// @inheritdoc IBlueberryStaking
    function completeVesting(
        uint256[] calldata _vestIndexes
    ) external whenNotPaused updateVests(msg.sender, _vestIndexes) {
        Vest[] storage vests = vesting[msg.sender];
        if (vesting[msg.sender].length < _vestIndexes.length) {
            revert InvalidLength();
        }

        uint256 totalbdblb;
        for (uint256 i; i < _vestIndexes.length; ++i) {
            Vest storage v = vests[_vestIndexes[i]];

            if (!isVestingComplete(msg.sender, _vestIndexes[i])) {
                revert VestingIncomplete();
            }

            totalbdblb += v.amount;
            delete vests[_vestIndexes[i]];
        }

        if (totalbdblb > 0) {
            blb.transfer(msg.sender, totalbdblb);
        }

        emit VestingCompleted(msg.sender, totalbdblb, block.timestamp);
    }

    /// @inheritdoc IBlueberryStaking
    function accelerateVesting(
        uint256[] calldata _vestIndexes
    ) external whenNotPaused updateVests(msg.sender, _vestIndexes) {
        // index must exist
        if (vesting[msg.sender].length < _vestIndexes.length) {
            revert InvalidLength();
        }

        // lockdrop period must be complete i.e 2 months
        if (block.timestamp <= deployedAt + 60 days) {
            revert LockdropIncomplete();
        }

        Vest[] storage vests = vesting[msg.sender];

        uint256 totalbdblb;
        uint256 totalRedistributedAmount;
        uint256 totalAccelerationFee;
        for (uint256 i; i < _vestIndexes.length; ++i) {
            uint256 _vestIndex = _vestIndexes[i];
            Vest storage _vest = vests[_vestIndex];
            uint256 _vestAmount = _vest.amount;

            if (_vestAmount <= 0) {
                revert NothingToUpdate();
            }

            uint256 _earlyUnlockPenaltyRatio = getEarlyUnlockPenaltyRatio(
                msg.sender,
                _vestIndex
            );

            if (_earlyUnlockPenaltyRatio == 0) {
                revert("Vest complete, nothing to accelerate");
            }

            // calculate acceleration fee and log it to ensure eth value is sent
            uint256 _accelerationFee = getAccelerationFeeStableAsset(
                msg.sender,
                _vestIndex
            );
            totalAccelerationFee += _accelerationFee;

            // calculate the amount of the vest that will be redistributed
            uint256 _redistributionAmount = (_vestAmount *
                _earlyUnlockPenaltyRatio) / 1e18;

            // get current epoch and redistribute to it
            uint256 _epoch = currentEpoch();
            epochs[_epoch].redistributedBLB += _redistributionAmount;

            // log it for the event
            totalRedistributedAmount += _redistributionAmount;

            // remove it from the recieved vest
            _vestAmount -= _redistributionAmount;

            // the remainder is withdrawable by the user
            totalbdblb += _vestAmount;

            // delete the vest
            delete vests[_vestIndex];
        }

        if (totalAccelerationFee > 0) {
            // transfer the acceleration fee to the treasury
            stableAsset.safeTransferFrom(
                msg.sender,
                treasury,
                totalAccelerationFee
            );
        }

        if (totalbdblb > 0) {
            blb.transfer(msg.sender, totalbdblb);
        }

        emit Accelerated(msg.sender, totalbdblb, totalRedistributedAmount);
    }

    /*//////////////////////////////////////////////////
                       VIEW FUNCTIONS
    //////////////////////////////////////////////////*/

    /// @inheritdoc IBlueberryStaking
    function fetchTWAP(uint32 _secondsInPast) public view returns (uint256) {
        IUniswapV3Pool _pool = IUniswapV3Pool(uniswapV3Pool);

        // max 5 days
        if (_secondsInPast > 432_000) {
            revert InvalidObservationTime();
        }

        uint32[] memory _secondsArray = new uint32[](2);

        _secondsArray[0] = _secondsInPast;
        _secondsArray[1] = 0;

        (int56[] memory tickCumulatives, ) = _pool.observe(_secondsArray);

        int56 _tickDifference = tickCumulatives[1] - tickCumulatives[0];
        int56 _timeDifference = int32(_secondsInPast);

        int24 _twapTick = int24(_tickDifference / _timeDifference);

        uint160 _sqrtPriceX96 = TickMath.getSqrtRatioAtTick(_twapTick);

        // Decode the square root price
        uint256 _priceX96 = FullMath.mulDiv(
            _sqrtPriceX96,
            _sqrtPriceX96,
            FixedPoint96.Q96
        );

        uint256 _decimalsBLB = 18;
        uint256 _decimalsStable = stableDecimals;

        // Adjust for decimals
        if (_decimalsBLB > _decimalsStable) {
            _priceX96 /= 10 ** (_decimalsBLB - _decimalsStable);
        } else if (_decimalsStable > _decimalsBLB) {
            _priceX96 *= 10 ** (_decimalsStable - _decimalsBLB);
        }

        // Now priceX96 is the price of blb in terms of stableAsset, multiplied by 2^96.
        // To convert this to a human-readable format, you can divide by 2^96:

        uint256 _price = _priceX96 / 2 ** 96;

        // Now 'price' is the price of blb in terms of stableAsset, in the correct decimal places.
        return _price;
    }

    /// @inheritdoc IBlueberryStaking
    function getPrice() public view returns (uint256 _price) {
        // during the lockdrop period the underlying blb token price is locked
        uint256 _month = (block.timestamp - deployedAt) / 30 days;
        // month 1: $0.02 / blb
        if (_month <= 1) {
            _price = 0.02e18;
        }
        // month 2: $0.04 / blb
        else if (_month <= 2 || uniswapV3Pool == address(0)) {
            _price = 0.04e18;
        }
        // month 3+
        else {
            // gets the price of BLB in USD averaged over the last hour
            _price = fetchTWAP(observationPeriod);
        }
    }

    /// @inheritdoc IBlueberryStaking
    function canClaim(address _user) public view returns (bool) {
        uint256 _currentEpoch = currentEpoch();
        return lastClaimedEpoch[_user] <= _currentEpoch;
    }

    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - deployedAt) / epochLength;
    }

    /// @inheritdoc IBlueberryStaking
    function isVestingComplete(
        address _user,
        uint256 _vestIndex
    ) public view returns (bool) {
        return
            vesting[_user][_vestIndex].startTime + vestLength <=
            block.timestamp;
    }

    /// @inheritdoc IBlueberryStaking
    function rewardPerToken(address _ibToken) public view returns (uint256) {
        if (totalSupply[_ibToken] == 0) {
            return rewardPerTokenStored[_ibToken];
        }

        /* if the reward period has finished, that timestamp is used to calculate the reward per token. */

        if (block.timestamp > finishAt) {
            return
                rewardPerTokenStored[_ibToken] +
                ((rewardRate[_ibToken] *
                    (finishAt - lastUpdateTime[_ibToken]) *
                    1e18) / totalSupply[_ibToken]);
        } else {
            return
                rewardPerTokenStored[_ibToken] +
                ((rewardRate[_ibToken] *
                    (block.timestamp - lastUpdateTime[_ibToken]) *
                    1e18) / totalSupply[_ibToken]);
        }
    }

    /// @inheritdoc IBlueberryStaking
    function earned(
        address _account,
        address _ibToken
    ) public view returns (uint256 earnedAmount) {
        return _earned(_account, _ibToken);
    }

    function _earned(
        address _account,
        address _ibToken
    ) internal view returns (uint256 earnedAmount) {
        uint256 _balance = balanceOf[_account][_ibToken];
        uint256 _rewardPerToken = rewardPerToken(_ibToken);
        uint256 _rewardPaid = userRewardPerTokenPaid[_account][_ibToken];
        earnedAmount =
            (_balance * (_rewardPerToken - _rewardPaid)) /
            1e18 +
            rewards[_account][_ibToken];
    }

    /// @inheritdoc IBlueberryStaking
    function lastTimeRewardApplicable() public view returns (uint256) {
        if (block.timestamp > finishAt) {
            return finishAt;
        } else {
            return block.timestamp;
        }
    }

    /**
     * @return the total amount of vesting tokens (bdblb)
     */
    function bdblbBalance(address _user) public view returns (uint256) {
        uint256 _balance;
        for (uint256 i; i < vesting[_user].length; ++i) {
            _balance += vesting[_user][i].amount;
        }
        return _balance;
    }

    /// @inheritdoc IBlueberryStaking
    function getEarlyUnlockPenaltyRatio(
        address _user,
        uint256 _vestingScheduleIndex
    ) public view returns (uint256 penaltyRatio) {
        uint256 _vestStartTime = vesting[_user][_vestingScheduleIndex]
            .startTime;
        uint256 _vestTimeElapsed = block.timestamp - _vestStartTime;

        // Calculate the early unlock penalty ratio based on the time passed and total vesting period

        // If the vesting period has occured the same block, the penalty ratio is 100% of the base penalty ratio
        if (_vestTimeElapsed <= 0) {
            penaltyRatio = basePenaltyRatioPercent;
        }
        // If the vesting period is mid-acceleration, calculate the penalty ratio based on the time passed
        else if (_vestTimeElapsed < vestLength) {
            penaltyRatio =
                ((vestLength - _vestTimeElapsed).divWad(vestLength) *
                    basePenaltyRatioPercent) /
                1e18;
        }
        // If the vesting period is over, return 0
        else {
            return 0;
        }
    }

    /// @inheritdoc IBlueberryStaking
    function getAccelerationFeeStableAsset(
        address _user,
        uint256 _vestingScheduleIndex
    ) public view returns (uint256 accelerationFee) {
        Vest storage _vest = vesting[_user][_vestingScheduleIndex];
        uint256 _earlyUnlockPenaltyRatio = getEarlyUnlockPenaltyRatio(
            _user,
            _vestingScheduleIndex
        );

        accelerationFee =
            ((((_vest.priceUnderlying * _vest.amount) / 1e18) *
                _earlyUnlockPenaltyRatio) / 1e18) /
            (10 ** (18 - stableDecimals));
    }

    /*//////////////////////////////////////////////////
                         MANAGEMENT
    //////////////////////////////////////////////////*/

    /// @inheritdoc IBlueberryStaking
    function changeBLB(address _blb) external onlyOwner {
        if (_blb == address(0)) {
            revert AddressZero();
        }
        blb = IBlueberryToken(_blb);

        emit BLBUpdated(_blb, block.timestamp);
    }

    /// @inheritdoc IBlueberryStaking
    function changeEpochLength(uint256 _epochLength) external onlyOwner {
        if (_epochLength == 0) {
            revert EpochLengthZero();
        }
        epochLength = _epochLength;

        emit EpochLengthUpdated(_epochLength, block.timestamp);
    }

    /// @inheritdoc IBlueberryStaking
    function addIbTokens(address[] calldata _ibTokens) external onlyOwner {
        totalIbTokens += _ibTokens.length;
        for (uint256 i; i < _ibTokens.length; ++i) {
            if (_ibTokens[i] == address(0)) {
                revert AddressZero();
            }

            if (isIbToken[_ibTokens[i]]) {
                revert BTokenAlreadyExists();
            }

            isIbToken[_ibTokens[i]] = true;
            ibTokens.push(_ibTokens[i]);
        }

        emit IbTokensAdded(_ibTokens, block.timestamp);
    }

    /// @inheritdoc IBlueberryStaking
    function removeIbTokens(address[] calldata _ibTokens) external onlyOwner {
        totalIbTokens -= _ibTokens.length;
        for (uint256 i; i < _ibTokens.length; ++i) {
            if (_ibTokens[i] == address(0)) {
                revert AddressZero();
            }

            if (!isIbToken[_ibTokens[i]]) {
                revert IbTokenDoesNotExist();
            }

            isIbToken[_ibTokens[i]] = false;
        }

        emit IbTokensRemoved(_ibTokens, block.timestamp);
    }

    /// @inheritdoc IBlueberryStaking
    function modifyRewardAmount(
        address[] calldata _ibTokens,
        uint256[] calldata _amounts
    ) external onlyOwner updateRewards(address(0), _ibTokens) {
        if (_amounts.length != _ibTokens.length) {
            revert InvalidLength();
        }

        for (uint256 i; i < _ibTokens.length; ++i) {
            address _ibToken = _ibTokens[i];
            uint256 _amount = _amounts[i];

            if (block.timestamp > finishAt) {
                rewardRate[_ibToken] = _amount / rewardDuration;
            } else {
                uint256 remaining = finishAt - block.timestamp;
                uint256 leftover = remaining * rewardRate[_ibToken];
                rewardRate[_ibToken] = (_amount + leftover) / rewardDuration;
            }

            if (rewardRate[_ibToken] == 0) {
                revert InvalidRewardRate();
            }

            finishAt = block.timestamp + rewardDuration;
            lastUpdateTime[_ibToken] = block.timestamp;
        }

        emit RewardAmountModified(_ibTokens, _amounts, block.timestamp);
    }

    /// @inheritdoc IBlueberryStaking
    function setRewardDuration(uint256 _rewardDuration) external onlyOwner {
        rewardDuration = _rewardDuration;

        emit RewardDurationUpdated(_rewardDuration, block.timestamp);
    }

    /// @inheritdoc IBlueberryStaking
    function setVestLength(uint256 _vestLength) external onlyOwner {
        vestLength = _vestLength;

        emit VestLengthUpdated(_vestLength, block.timestamp);
    }

    /// @inheritdoc IBlueberryStaking
    function setBasePenaltyRatioPercent(uint256 _ratio) external onlyOwner {
        if (_ratio > 1e18) {
            revert InvalidPenaltyRatio();
        }
        basePenaltyRatioPercent = _ratio;

        emit BasePenaltyRatioChanged(_ratio, block.timestamp);
    }

    /**
     * @notice Changes the address of stable asset to an alternative in the event of a depeg
     * @param _stableAsset The new stable asset address
     * @param _decimals The decimals of the new stableAsset
     */
    function changeStableAddress(
        address _stableAsset,
        uint256 _decimals
    ) external onlyOwner {
        if (_stableAsset == address(0)) {
            revert AddressZero();
        }
        stableAsset = IERC20(_stableAsset);
        stableDecimals = _decimals;

        emit StableAssetUpdated(_stableAsset, _decimals, block.timestamp);
    }

    /// @inheritdoc IBlueberryStaking
    function changeTreasuryAddress(address _treasury) external onlyOwner {
        if (_treasury == address(0)) {
            revert AddressZero();
        }
        treasury = _treasury;

        emit TreasuryUpdated(_treasury, block.timestamp);
    }

    /// @inheritdoc IBlueberryStaking
    function changeUniswapInformation(
        address _uniswapPool,
        address _uniswapFactory,
        uint32 _observationPeriod
    ) external onlyOwner {
        if (_uniswapPool == address(0) || _uniswapFactory == address(0)) {
            revert AddressZero();
        }
        if (_observationPeriod == 0) {
            revert InvalidObservationTime();
        }

        uniswapV3Pool = _uniswapPool;
        uniswapV3Factory = _uniswapFactory;
        observationPeriod = _observationPeriod;
    }

    /// @inheritdoc IBlueberryStaking
    function pause() external onlyOwner {
        _pause();
    }

    /// @inheritdoc IBlueberryStaking
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @inheritdoc IBlueberryStaking
    function setIbTokenArray(address[] calldata _ibTokens) external onlyOwner {
        // Make sure the storage variable has already been set
        if (ibTokens.length > 0) {
            revert ArrayAlreadySet();
        }
        ibTokens = _ibTokens;
    }
    
    /// @inheritdoc IBlueberryStaking
    function getAccumulatedRewards(address _user) external view returns (uint256 _totalRewards) {
        address[] memory cachedTokens = ibTokens;
        uint256 cachedLength = cachedTokens.length;

        for (uint256 i; i < cachedLength; ++i) {
            if (isIbToken[cachedTokens[i]]) {
                _totalRewards += _earned(_user, cachedTokens[i]);
            }
        }
    }

    receive() external payable {}

    fallback() external payable {}
}
