pragma solidity ^0.5.8;

import "@aragon/os/contracts/lib/token/ERC20.sol";
import "@aragon/os/contracts/common/SafeERC20.sol";
import "@aragon/os/contracts/common/IsContract.sol";
import "@aragon/os/contracts/lib/math/SafeMath.sol";
import "@aragon/os/contracts/common/TimeHelpers.sol";

import "../lib/PctHelpers.sol";
import "../registry/IJurorsRegistry.sol";
import "../subscriptions/ISubscriptions.sol";
import "../subscriptions/ISubscriptionsOwner.sol";


contract CourtSubscriptions is IsContract, ISubscriptions, TimeHelpers {
    using SafeERC20 for ERC20;
    using SafeMath for uint256;
    using PctHelpers for uint256;

    string internal constant ERROR_NOT_GOVERNOR = "SUB_NOT_GOVERNOR";
    string internal constant ERROR_OWNER_ALREADY_SET = "SUB_OWNER_ALREADY_SET";
    string internal constant ERROR_ZERO_TRANSFER = "SUB_ZERO_TRANSFER";
    string internal constant ERROR_TOKEN_TRANSFER_FAILED = "SUB_TOKEN_TRANSFER_FAILED";
    string internal constant ERROR_ZERO_PERIOD_DURATION = "SUB_ZERO_PERIOD_DURATION";
    string internal constant ERROR_ZERO_FEE = "SUB_ZERO_FEE";
    string internal constant ERROR_NOT_CONTRACT = "SUB_NOT_CONTRACT";
    string internal constant ERROR_ZERO_PREPAYMENT_PERIODS = "SUB_ZERO_PREPAYMENT_PERIODS";
    string internal constant ERROR_OVERFLOW = "SUB_OVERFLOW";
    string internal constant ERROR_INVALID_PERIOD = "SUB_INVALID_PERIOD";
    string internal constant ERROR_ALREADY_CLAIMED = "SUB_ALREADY_CLAIMED";
    string internal constant ERROR_NOTHING_TO_CLAIM = "SUB_NOTHING_TO_CLAIM";
    string internal constant ERROR_PAY_ZERO_PERIODS = "SUB_PAY_ZERO_PERIODS";
    string internal constant ERROR_TOO_MANY_PERIODS = "SUB_TOO_MANY_PERIODS";

    // Term 0 is for jurors on-boarding
    uint64 internal constant START_TERM_ID = 1;

    struct Subscriber {
        bool subscribed;                        // Whether or not a user has been subscribed to the Court, subscriptions cannot be rolled back
        uint64 lastPaymentPeriodId;             // Identification number of the last period paid by a subscriber
    }

    struct Period {
        uint64 balanceCheckpoint;               // Court term id of a period used to fetch the total active balance of the jurors registry
        ERC20 feeToken;                         // Fee token corresponding to a certain subscription period
        uint256 feeAmount;                      // Amount of fees paid for a certain subscription period
        uint256 totalActiveBalance;             // Total amount of juror tokens active in the Court at the corresponding period checkpoint
        uint256 collectedFees;                  // Total amount of subscription fees collected during a period
        mapping (address => bool) claimedFees;  // List of jurors that have claimed fees during a period, indexed by juror address
    }

    // Subscriptions owner address
    ISubscriptionsOwner internal owner;

    // Registry of jurors
    IJurorsRegistry internal jurorsRegistry;

    // Duration of a subscription period in Court terms
    uint64 internal periodDuration;

    // Per ten thousand of subscription fees that will be applied as penalty for not paying during proper period (‱ - 1/10,000)
    uint16 public latePaymentPenaltyPct;

    // Per ten thousand of subscription fees that will be allocated to the governor of the Court (‱ - 1/10,000)
    uint16 public governorSharePct;

    // ERC20 token used for the subscription fees
    ERC20 public currentFeeToken;

    // Amount of fees to be paid for each subscription period
    uint256 public currentFeeAmount;

    // Number of periods that can be paid in advance including the current period. Paying in advance has some drawbacks:
    // - Fee amount could increase, while pre-payments would be made with the old rate.
    // - Fees are distributed among jurors when the payment is made, so jurors activating after a pre-payment won't get their share of it.
    uint256 public prePaymentPeriods;

    // Total amount of fees accumulated for the governor of the Court
    uint256 public accumulatedGovernorFees;

    // List of subscribers indexed by address
    mapping (address => Subscriber) internal subscribers;

    // List of periods indexed by ID
    mapping (uint256 => Period) internal periods;

    event FeesPaid(address indexed subscriber, uint256 periods, uint256 newLastPeriodId, uint256 collectedFees, uint256 governorFee);
    event FeesClaimed(address indexed juror, uint256 indexed periodId, uint256 jurorShare);
    event GovernorFeesTransferred(uint256 amount);

    /**
    * @dev Ensure the msg.sender is the governor of the Court
    */
    modifier onlyGovernor {
        require(msg.sender == owner.getGovernor(), ERROR_NOT_GOVERNOR);
        _;
    }

    /**
    * @dev Initialize court subscriptions
    * @param _owner Address to be set as the owner of the court subscriptions
    * @param _jurorsRegistry Address of the JurorsRegistry component of the Court
    * @param _periodDuration Initial duration of a subscription period in Court terms
    * @param _feeToken Initial ERC20 token used for the subscription fees
    * @param _feeAmount Initial amount of fees to be paid for each subscription period
    * @param _prePaymentPeriods Initial number of periods that can be paid in advance including the current period
    * @param _latePaymentPenaltyPct Initial per ten thousand of subscription fees that will be applied as penalty for not paying during proper period (‱ - 1/10,000)
    * @param _governorSharePct Initial per ten thousand of subscription fees that will be allocated to the governor of the Court (‱ - 1/10,000)
    */
    function init(
        ISubscriptionsOwner _owner,
        IJurorsRegistry _jurorsRegistry,
        uint64 _periodDuration,
        ERC20 _feeToken,
        uint256 _feeAmount,
        uint256 _prePaymentPeriods,
        uint16 _latePaymentPenaltyPct,
        uint16 _governorSharePct
    )
        external
    {
        // TODO: cannot check the given owner is a contract cause the Court set this up in the constructor, move to a factory
        require(address(owner) == address(0), ERROR_OWNER_ALREADY_SET);
        require(_periodDuration > 0, ERROR_ZERO_PERIOD_DURATION);

        owner = _owner;
        jurorsRegistry = _jurorsRegistry;
        periodDuration = _periodDuration;
        _setFeeToken(_feeToken);
        _setFeeAmount(_feeAmount);
        _setPrePaymentPeriods(_prePaymentPeriods);
        latePaymentPenaltyPct = _latePaymentPenaltyPct;
        _setGovernorSharePct(_governorSharePct);
    }

    /**
    * @notice Pay fees on behalf of `_from` for `_periods` periods
    * @param _from Subscriber whose subscription is being paid
    * @param _periods Number of periods to be paid in total since the last paid period
    */
    function payFees(address _from, uint256 _periods) external {
        require(_periods > 0, ERROR_PAY_ZERO_PERIODS);

        Subscriber storage subscriber = subscribers[_from];
        uint256 currentPeriodId = _getCurrentPeriodId();
        Period storage period = periods[currentPeriodId];

        (ERC20 feeToken, uint256 feeAmount) = _ensurePeriodFeeTokenAndAmount(period);

        // Compute the total amount to pay by sender on behalf of the subscriber, including the penalties for delayed periods
        (uint256 amountToPay, uint256 newLastPeriodId) = _getPayFeesDetails(subscriber, _periods, currentPeriodId, feeAmount);

        // Compute the portion of the total amount to pay that will be allocated to the governor
        uint256 governorFee = amountToPay.pct(governorSharePct);
        accumulatedGovernorFees += governorFee;

        // Note that it is safe to avoid SafeMath here since the governor share cannot be above 100%. Thus, the highest governor fees we
        // could have is equal to the amount to be paid.
        uint256 collectedFees = amountToPay - governorFee;
        period.collectedFees += collectedFees;

        // Initialize subscription for the requested subscriber if it is the first time paying fees
        if (!subscriber.subscribed) {
            subscriber.subscribed = true;
        }

        // Periods are measured in Court terms. Since Court terms are represented in `uint64`, we are safe to use `uint64` for period ids too.
        subscriber.lastPaymentPeriodId = uint64(newLastPeriodId);

        // Deposit fee tokens from sender to this contract
        emit FeesPaid(_from, _periods, newLastPeriodId, collectedFees, governorFee);
        require(feeToken.safeTransferFrom(msg.sender, address(this), amountToPay), ERROR_TOKEN_TRANSFER_FAILED);
    }

    /**
    * @notice Claim proportional share fees for period `_periodId` owed to `msg.sender`
    * @param _periodId Identification number of the period which fees are claimed for
    */
    function claimFees(uint256 _periodId) external {
        // Juror share fees can only be claimed for past periods
        require(_periodId < _getCurrentPeriodId(), ERROR_INVALID_PERIOD);
        Period storage period = periods[_periodId];
        require(!period.claimedFees[msg.sender], ERROR_ALREADY_CLAIMED);

        // Check claiming juror has share fees to be transferred
        (uint64 periodBalanceCheckpoint, uint256 totalActiveBalance) = _ensurePeriodBalanceDetails(_periodId, period);
        uint256 jurorShare = _getJurorShare(msg.sender, period, periodBalanceCheckpoint, totalActiveBalance);
        require(jurorShare > 0, ERROR_NOTHING_TO_CLAIM);

        // Update juror state and transfer share fees
        period.claimedFees[msg.sender] = true;
        emit FeesClaimed(msg.sender, _periodId, jurorShare);
        require(period.feeToken.safeTransfer(msg.sender, jurorShare), ERROR_TOKEN_TRANSFER_FAILED);
    }

    /**
    * @notice Transfer owed fees to the governor
    */
    function transferFeesToGovernor() external {
        require(accumulatedGovernorFees > 0, ERROR_ZERO_TRANSFER);
        _transferFeesToGovernor();
    }

    /**
    * @notice Make sure that the balance details of a certain period have been computed
    * @param _periodId Identification number of the period being ensured
    * @return periodBalanceCheckpoint Court term id used to fetch the total active balance of the jurors registry
    * @return totalActiveBalance Total amount of juror tokens active in the Court at the corresponding used checkpoint
    */
    function ensurePeriodBalanceDetails(uint256 _periodId) external returns (uint64 periodBalanceCheckpoint, uint256 totalActiveBalance) {
        Period storage period = periods[_periodId];
        return _ensurePeriodBalanceDetails(_periodId, period);
    }

    /**
    * @notice Set new subscriptions fee amount to `_feeAmount`
    * @param _feeAmount New amount of fees to be paid for each subscription period
    */
    function setFeeAmount(uint256 _feeAmount) external onlyGovernor {
        _setFeeAmount(_feeAmount);
    }

    /**
    * @notice Set new subscriptions fee to `@tokenAmount(_feeToken, _feeAmount)`
    * @dev Accumulated fees owed to governor (if any) will be transferred
    * @param _feeToken New ERC20 token to be used for the subscription fees
    * @param _feeAmount New amount of fees to be paid for each subscription period
    */
    function setFeeToken(ERC20 _feeToken, uint256 _feeAmount) external onlyGovernor {
        // `setFeeToken` transfers governor's accumulated fees, so must be executed first
        _setFeeToken(_feeToken);
        _setFeeAmount(_feeAmount);
    }

    /**
    * @notice Set new number of pre payment to `_prePaymentPeriods` periods
    * @param _prePaymentPeriods New number of periods that can be paid in advance
    */
    function setPrePaymentPeriods(uint256 _prePaymentPeriods) external onlyGovernor {
        _setPrePaymentPeriods(_prePaymentPeriods);
    }

    /**
    * @notice Set new late payment penalty `_latePaymentPenaltyPct`‱ (1/10,000)
    * @param _latePaymentPenaltyPct New per ten thousand of subscription fees that will be applied as penalty for not paying during proper period
    */
    function setLatePaymentPenaltyPct(uint16 _latePaymentPenaltyPct) external onlyGovernor {
        latePaymentPenaltyPct = _latePaymentPenaltyPct;
    }

    /**
    * @notice Set new governor share to `_governorSharePct`‱ (1/10,000)
    * @param _governorSharePct New per ten thousand of subscription fees that will be allocated to the governor of the Court (‱ - 1/10,000)
    */
    function setGovernorSharePct(uint16 _governorSharePct) external onlyGovernor {
        _setGovernorSharePct(_governorSharePct);
    }

    /**
    * @dev Tell the address of the owner of the contract
    * @return Address of owner
    */
    function getOwner() external view returns (address) {
        return address(owner);
    }

    /**
    * @dev Tell whether a certain subscriber has paid all the fees up to current period or not
    * @param _subscriber Address of subscriber being checked
    * @return True if subscriber has paid all the fees up to current period, false otherwise
    */
    function isUpToDate(address _subscriber) external view returns (bool) {
        Subscriber storage subscriber = subscribers[_subscriber];
        return subscriber.subscribed && subscriber.lastPaymentPeriodId >= _getCurrentPeriodId();
    }

    /**
    * @dev Tell the identification number of the current period
    * @return Identification number of the current period
    */
    function getCurrentPeriodId() external view returns (uint256) {
        return _getCurrentPeriodId();
    }

    /**
    * @dev Tell total active balance of the jurors registry at a random term during a certain period
    * @param _periodId Identification number of the period being queried
    * @return periodBalanceCheckpoint Court term id used to fetch the total active balance of the jurors registry
    * @return totalActiveBalance Total amount of juror tokens active in the Court at the corresponding used checkpoint
    */
    function getPeriodBalanceDetails(uint256 _periodId) external view returns (uint64 periodBalanceCheckpoint, uint256 totalActiveBalance) {
        return _getPeriodBalanceDetails(_periodId);
    }

    /**
    * @dev Tell the number of overdue payments for a given subscriber
    * @param _subscriber Address of the subscriber being checked
    * @return Number of overdue payments for the requested subscriber
    */
    function getDelayedPeriods(address _subscriber) external view returns (uint256) {
        Subscriber storage subscriber = subscribers[_subscriber];
        uint256 currentPeriodId = _getCurrentPeriodId();
        uint256 lastPaymentPeriodId = subscriber.lastPaymentPeriodId;

        if (!subscriber.subscribed || lastPaymentPeriodId >= currentPeriodId) {
            // If the given subscriber was not subscribed yet, there are no pending payments
            return 0;
        } else {
            // If the given subscriber was already subscribed, then the current period is not considered delayed
            return currentPeriodId - lastPaymentPeriodId - 1;
        }
    }

    /**
    * @dev Tell the amount to pay and resulting last paid period for a given subscriber paying for a certain number of periods
    * @param _subscriber Address of the subscriber willing to pay
    * @param _periods Number of periods that would be paid
    * @return tokenAddress Address of the token used for the subscription fees
    * @return amountToPay Amount of subscription fee tokens to be paid
    * @return newLastPeriodId Identification number of the resulting last paid period
    */
    function getPayFeesDetails(address _subscriber, uint256 _periods) external view
        returns (address tokenAddress, uint256 amountToPay, uint256 newLastPeriodId)
    {
        Subscriber storage subscriber = subscribers[_subscriber];
        uint256 currentPeriodId = _getCurrentPeriodId();

        (ERC20 feeToken, uint256 feeAmount) = _getPeriodFeeTokenAndAmount(periods[currentPeriodId]);
        tokenAddress = address(feeToken);

        // total amount to pay by sender (on behalf of org), including penalties for delayed periods
        (amountToPay, newLastPeriodId) = _getPayFeesDetails(subscriber, _periods, currentPeriodId, feeAmount);
    }

    /**
    * @dev Tell the share fees corresponding to a juror for a certain period
    * @param _juror Address of the juror querying the owed shared fees of
    * @param _periodId Identification number of the period being queried
    * @return Address of the token used for the subscription fees
    * @return Amount of share fees owed to the given juror for the requested period
    */
    function getJurorShare(address _juror, uint256 _periodId) external view returns (address tokenAddress, uint256 jurorShare) {
        Period storage period = periods[_periodId];
        uint64 periodBalanceCheckpoint;
        uint256 totalActiveBalance = period.totalActiveBalance;

        // Compute period balance details if they were not ensured yet
        if (totalActiveBalance == 0) {
            (periodBalanceCheckpoint, totalActiveBalance) = _getPeriodBalanceDetails(_periodId);
        } else {
            periodBalanceCheckpoint = period.balanceCheckpoint;
        }

        // Compute juror share fees using the period balance details
        jurorShare = _getJurorShare(_juror, period, periodBalanceCheckpoint, totalActiveBalance);
        (ERC20 feeToken,) = _getPeriodFeeTokenAndAmount(period);
        tokenAddress = address(feeToken);
    }

    /**
    * @dev Check if a given juror has already claimed the owed share fees for a certain period
    * @param _juror Address of the juror being queried
    * @param _periodId Identification number of the period being queried
    * @return True if the owed share fees have already been claimed, false otherwise
    */
    function hasJurorClaimed(address _juror, uint256 _periodId) external view returns (bool) {
        return periods[_periodId].claimedFees[_juror];
    }

    /**
    * @dev Internal function to transfer owed fees to the governor. This function assumes there are some accumulated fees to be transferred.
    */
    function _transferFeesToGovernor() internal {
        uint256 amount = accumulatedGovernorFees;
        accumulatedGovernorFees = 0;
        emit GovernorFeesTransferred(amount);
        require(currentFeeToken.safeTransfer(owner.getGovernor(), amount), ERROR_TOKEN_TRANSFER_FAILED);
    }

    /**
    * @dev Internal function to make sure the fee token address and amount of a certain period have been cached
    * @param _period Period being ensured to have cached its fee token address and amount
    * @return feeToken ERC20 token to be used for the subscription fees during the given period
    * @return feeAmount Amount of fees to be paid during the given period
    */
    function _ensurePeriodFeeTokenAndAmount(Period storage _period) internal returns (ERC20 feeToken, uint256 feeAmount) {
        // Use current fee token address and amount for the given period if these haven't been set yet
        feeToken = _period.feeToken;
        if (feeToken == ERC20(0)) {
            feeToken = currentFeeToken;
            _period.feeToken = feeToken;
            _period.feeAmount = currentFeeAmount;
        }
        feeAmount = _period.feeAmount;
    }

    /**
    * @dev Internal function to make sure that the balance details of a certain period have been computed. This function assumes given ID and
    *      period correspond to each other.
    * @param _periodId Identification number of the period being ensured
    * @param _period Period being ensured
    * @return periodBalanceCheckpoint Court term id used to fetch the total active balance of the jurors registry
    * @return totalActiveBalance Total amount of juror tokens active in the Court at the corresponding used checkpoint
    */
    function _ensurePeriodBalanceDetails(uint256 _periodId, Period storage _period) internal
        returns (uint64 periodBalanceCheckpoint, uint256 totalActiveBalance)
    {
        totalActiveBalance = _period.totalActiveBalance;

        // Set balance details for the given period if these haven't been set yet
        if (totalActiveBalance == 0) {
            (periodBalanceCheckpoint, totalActiveBalance) = _getPeriodBalanceDetails(_periodId);
            _period.balanceCheckpoint = periodBalanceCheckpoint;
            _period.totalActiveBalance = totalActiveBalance;
        } else {
            periodBalanceCheckpoint = _period.balanceCheckpoint;
        }
    }

    /**
    * @dev Internal function to set a new amount for the subscription fees
    * @param _feeAmount New amount of fees to be paid for each subscription period
    */
    function _setFeeAmount(uint256 _feeAmount) internal {
        require(_feeAmount > 0, ERROR_ZERO_FEE);
        currentFeeAmount = _feeAmount;
    }

    /**
    * @dev Internal function to set a new ERC20 token for the subscription fees
    * @param _feeToken New ERC20 token to be used for the subscription fees
    */
    function _setFeeToken(ERC20 _feeToken) internal {
        require(isContract(address(_feeToken)), ERROR_NOT_CONTRACT);
        if (accumulatedGovernorFees > 0) {
            _transferFeesToGovernor();
        }
        currentFeeToken = _feeToken;
    }

    /**
    * @dev Internal function to set a new number of pre payment periods
    * @param _prePaymentPeriods New number of periods that can be paid in advance including the current period
    */
    function _setPrePaymentPeriods(uint256 _prePaymentPeriods) internal {
        // The pre payments period number must contemplate the current period. Thus, it must be greater than zero.
        require(_prePaymentPeriods > 0, ERROR_ZERO_PREPAYMENT_PERIODS);
        prePaymentPeriods = _prePaymentPeriods;
    }

    /**
    * @dev Internal function to set a new governor share value
    * @param _governorSharePct New per ten thousand of subscription fees that will be allocated to the governor of the Court (‱ - 1/10,000)
    */
    function _setGovernorSharePct(uint16 _governorSharePct) internal {
        // Check governor share is not greater than 10,000‱
        require(PctHelpers.isValid(_governorSharePct), ERROR_OVERFLOW);
        governorSharePct = _governorSharePct;
    }

    /**
    * @dev Internal function to tell the identification number of the current period
    * @return Identification number of the current period
    */
    function _getCurrentPeriodId() internal view returns (uint256) {
        // Since the Court starts at term #1, and the first subscription period is #0, then subtract one unit to the current term of the Court
        return uint256(owner.getCurrentTermId()).sub(START_TERM_ID) / periodDuration;
    }

    /**
    * @dev Internal function to get the Court term in which a certain period starts
    * @param _periodId Identification number of the period querying the start term of
    * @return Court term where the given period starts
    */
    function _getPeriodStartTermId(uint256 _periodId) internal view returns (uint64) {
        // Periods are measured in Court terms. Since Court terms are represented in `uint64`, we are safe to use `uint64` for period ids too.
        return START_TERM_ID + uint64(_periodId) * periodDuration;
    }

    /**
    * @dev Internal function to get the fee token address and amount to be used for a certain period
    * @param _period Period querying the token address and amount of
    * @return feeToken ERC20 token to be used for the subscription fees during the given period
    * @return feeAmount Amount of fees to be paid during the given period
    */
    function _getPeriodFeeTokenAndAmount(Period storage _period) internal view returns (ERC20 feeToken, uint256 feeAmount) {
        // Return current fee token address and amount if these haven't been set for the given period yet
        feeToken = _period.feeToken;
        if (feeToken == ERC20(0)) {
            feeToken = currentFeeToken;
            feeAmount = currentFeeAmount;
        } else {
            feeAmount = _period.feeAmount;
        }
    }

    /**
    * @dev Internal function to compute the total amount of fees to be paid for the subscriber based on a requested number of periods
    * @param _subscriber Subscriber willing to pay
    * @param _periods Number of periods that would be paid
    * @param _currentPeriodId Identification number of the current period
    * @param _feeAmount Amount of fees to be paid for each subscription period
    * @return amountToPay Amount of subscription fee tokens to be paid
    * @return newLastPeriodId Identification number of the resulting last paid period
    */
    function _getPayFeesDetails(Subscriber storage _subscriber, uint256 _periods, uint256 _currentPeriodId, uint256 _feeAmount) internal view
        returns (uint256 amountToPay, uint256 newLastPeriodId)
    {
        uint256 lastPaymentPeriodId = _subscriber.lastPaymentPeriodId;
        uint256 delayedPeriods = 0;
        uint256 regularPeriods = 0;

        // Check if the subscriber has already been subscribed
        if (!_subscriber.subscribed) {
            // Not yet subscribed organisations don't have pending payments
            regularPeriods = _periods;
            // The number of periods to be paid includes the current period, thus we subtract one unit.
            // Note that there is no need to use SafeMath here since the number of periods is at least one.
            newLastPeriodId = _currentPeriodId + _periods - 1;
        } else {
            // Compute number of delayed periods if there are some, current period is not considered as delayed
            //
            //   subs      last           cur       new
            //  +----+----+----+----+----+----+----+----+
            //                 <---------><------------->
            //                   delayed      regular
            //                 <------------------------>
            //                         _periods
            if (_currentPeriodId > lastPaymentPeriodId + 1) {
                delayedPeriods = _currentPeriodId - lastPaymentPeriodId - 1;
            }
            // If the number of delayed periods is greater than the requested number of periods to be paid, cap the number of delayed periods,
            // otherwise, compute the number of regular periods to be paid
            if (delayedPeriods > _periods) {
                delayedPeriods = _periods;
            } else {
                regularPeriods = _periods - delayedPeriods;
            }
            newLastPeriodId = lastPaymentPeriodId + _periods;
        }

        // Check periods being paid in advance
        require(newLastPeriodId <= _currentPeriodId || newLastPeriodId.sub(_currentPeriodId) < prePaymentPeriods, ERROR_TOO_MANY_PERIODS);

        // Compute amount to be paid: delayedPeriods * _feeAmount * (1 + latePaymentPenaltyPct/PCT_BASE) + regularPeriods * _feeAmount
        amountToPay = delayedPeriods.mul(_feeAmount).pctIncrease(latePaymentPenaltyPct).add(regularPeriods.mul(_feeAmount));
    }

    /**
    * @dev Internal function to get the total active balance of the jurors registry at a random term during a period
    * @param _periodId Identification number of the period being queried
    * @return periodBalanceCheckpoint Court term id used to fetch the total active balance of the jurors registry
    * @return totalActiveBalance Total amount of juror tokens active in the Court at the corresponding used checkpoint
    */
    function _getPeriodBalanceDetails(uint256 _periodId) internal view returns (uint64 periodBalanceCheckpoint, uint256 totalActiveBalance) {
        uint64 periodStartTermId = _getPeriodStartTermId(_periodId);
        uint64 nextPeriodStartTermId = _getPeriodStartTermId(_periodId + 1);

        // Pick a random Court term during the next period of the requested one to get the total amount of juror tokens active in the Court
        bytes32 randomness = owner.getTermRandomness(nextPeriodStartTermId);

        // The randomness factor for each Court term is computed using the the hash of a block number set during the initialization of the
        // term, to ensure it cannot be known beforehand. Note that the hash function being used only works for the 256 most recent block
        // numbers. Therefore, if that occurs we use the hash of the previous block number. This could be slightly beneficial for the first juror
        // calling this function, but it's still impossible to predict during the requested period.
        if (randomness == bytes32(0)) {
            randomness = blockhash(getBlockNumber() - 1);
        }

        // Use randomness to choose a Court term of the requested period and query the total amount of juror tokens active at that term
        periodBalanceCheckpoint = periodStartTermId + uint64(uint256(randomness) % periodDuration);
        totalActiveBalance = jurorsRegistry.totalActiveBalanceAt(periodBalanceCheckpoint);
    }

    /**
    * @dev Internal function to tell the share fees corresponding to a juror for a certain period
    * @param _juror Address of the juror querying the owed shared fees of
    * @param _period Period being queried
    * @param _periodBalanceCheckpoint Court term id used to fetch the active balance of the juror for the requested period
    * @param _totalActiveBalance Total amount of juror tokens active in the Court at the corresponding used checkpoint
    * @return Amount of share fees owed to the given juror for the requested period
    */
    function _getJurorShare(address _juror, Period storage _period, uint64 _periodBalanceCheckpoint, uint256 _totalActiveBalance) internal view
        returns (uint256)
    {
        // Fetch juror active balance at the checkpoint used for the requested period
        uint256 jurorActiveBalance = jurorsRegistry.activeBalanceOfAt(_juror, _periodBalanceCheckpoint);
        if (jurorActiveBalance == 0) {
            return 0;
        }

        // Note that we already checked the juror active balance is greater than zero, then, the total active balance must be greater than zero.
        return _period.collectedFees.mul(jurorActiveBalance) / _totalActiveBalance;
    }
}
