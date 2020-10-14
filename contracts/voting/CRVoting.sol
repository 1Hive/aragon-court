pragma solidity ^0.5.8;

import "../lib/os/SafeMath.sol";

import "./ICRVoting.sol";
import "./ICRVotingOwner.sol";
import "../court/controller/Controlled.sol";
import "../court/controller/Controller.sol";
import "../lib/BytesHelpers.sol";


contract CRVoting is Controlled, ICRVoting {
    using SafeMath for uint256;
    using BytesHelpers for bytes;

    string private constant ERROR_VOTE_ALREADY_EXISTS = "CRV_VOTE_ALREADY_EXISTS";
    string private constant ERROR_VOTE_DOES_NOT_EXIST = "CRV_VOTE_DOES_NOT_EXIST";
    string private constant ERROR_VOTE_ALREADY_COMMITTED = "CRV_VOTE_ALREADY_COMMITTED";
    string private constant ERROR_VOTE_ALREADY_REVEALED = "CRV_VOTE_ALREADY_REVEALED";
    string private constant ERROR_INVALID_OUTCOME = "CRV_INVALID_OUTCOME";
    string private constant ERROR_INVALID_OUTCOMES_AMOUNT = "CRV_INVALID_OUTCOMES_AMOUNT";
    string private constant ERROR_INVALID_COMMITMENT_SALT = "CRV_INVALID_COMMITMENT_SALT";
    string private constant ERROR_SENDER_NOT_VERIFIED = "CRV_SENDER_NOT_VERIFIED";
    string private constant ERROR_SENDER_NOT_BRIGHTID_REGISTER = "CRV_SENDER_NOT_BRIGHTID_REGISTER";
    string private constant ERROR_NO_FUNCTION_MATCH = "CRV_NO_FUNCTION_MATCH";


    // Outcome nr. 0 is used to denote a missing vote (default)
    uint8 internal constant OUTCOME_MISSING = uint8(0);
    // Outcome nr. 1 is used to denote a leaked vote
    uint8 internal constant OUTCOME_LEAKED = uint8(1);
    // Outcome nr. 2 is used to denote a refused vote
    uint8 internal constant OUTCOME_REFUSED = uint8(2);
    // Besides the options listed above, every vote instance must provide at least 2 outcomes
    uint8 internal constant MIN_POSSIBLE_OUTCOMES = uint8(2);
    // Max number of outcomes excluding the default ones
    uint8 internal constant MAX_POSSIBLE_OUTCOMES = uint8(-1) - 3;

    struct CastVote {
        bytes32 commitment;                         // Hash of the outcome casted by the voter
        uint8 outcome;                              // Outcome submitted by the voter
    }

    struct Vote {
        uint8 winningOutcome;                       // Outcome winner of a vote instance
        uint8 maxAllowedOutcome;                    // Highest outcome allowed for the vote instance
        mapping (address => CastVote) votes;        // Mapping of voters addresses to their casted votes
        mapping (uint8 => uint256) outcomesTally;   // Tally for each of the possible outcomes
    }

    // Vote records indexed by their ID
    mapping (uint256 => Vote) internal voteRecords;

    event VotingCreated(uint256 indexed voteId, uint8 possibleOutcomes);
    event VoteCommitted(uint256 indexed voteId, address indexed voter, bytes32 commitment);
    event VoteRevealed(uint256 indexed voteId, address indexed voter, uint8 outcome, address revealer);
    event VoteLeaked(uint256 indexed voteId, address indexed voter, uint8 outcome, address leaker);

    /**
    * @dev Ensure a certain vote exists
    * @param _voteId Identification number of the vote to be checked
    */
    modifier voteExists(uint256 _voteId) {
        Vote storage vote = voteRecords[_voteId];
        require(_existsVote(vote), ERROR_VOTE_DOES_NOT_EXIST);
        _;
    }

    /**
    * @dev Constructor function
    * @param _controller Address of the controller
    */
    constructor(Controller _controller) Controlled(_controller) public {
        // solium-disable-previous-line no-empty-blocks
    }

    /**
    * @notice Create a new vote instance with ID #`_voteId` and `_possibleOutcomes` possible outcomes
    * @dev This function can only be called by the CRVoting owner
    * @param _voteId ID of the new vote instance to be created
    * @param _possibleOutcomes Number of possible outcomes for the new vote instance to be created
    */
    function create(uint256 _voteId, uint8 _possibleOutcomes) external onlyDisputeManager {
        require(_possibleOutcomes >= MIN_POSSIBLE_OUTCOMES && _possibleOutcomes <= MAX_POSSIBLE_OUTCOMES, ERROR_INVALID_OUTCOMES_AMOUNT);

        Vote storage vote = voteRecords[_voteId];
        require(!_existsVote(vote), ERROR_VOTE_ALREADY_EXISTS);

        // No need for SafeMath: we already checked the number of outcomes above
        vote.maxAllowedOutcome = OUTCOME_REFUSED + _possibleOutcomes;
        emit VotingCreated(_voteId, _possibleOutcomes);
    }

    /**
    * @notice Commit a vote for vote #`_voteId`
    * @param _voteId ID of the vote instance to commit a vote to
    * @param _commitment Hashed outcome to be stored for future reveal
    */
    function commit(uint256 _voteId, bytes32 _commitment) external voteExists(_voteId) {
        require(_brightIdRegister().isVerified(msg.sender), ERROR_SENDER_NOT_VERIFIED);
        address voterUniqueId = _voterUniqueId(msg.sender);

        _commit(_voteId, _commitment, voterUniqueId);
    }

    /**
    * @notice Leak `_outcome` vote of `_voter` for vote #`_voteId`
    * @param _voteId ID of the vote instance to leak a vote of
    * @param _voter Address of the voter to leak a vote of
    * @param _outcome Outcome leaked for the voter
    * @param _salt Salt to decrypt and validate the committed vote of the voter
    */
    function leak(uint256 _voteId, address _voter, uint8 _outcome, bytes32 _salt) external voteExists(_voteId) {
        address voterUniqueId = _voterUniqueId(_voter);
        CastVote storage castVote = voteRecords[_voteId].votes[voterUniqueId];
        _checkValidSalt(castVote, _outcome, _salt);
        _ensureCanCommit(_voteId);

        // There is no need to check if an outcome is valid if it was leaked.
        // Additionally, leaked votes are not considered for the tally.
        castVote.outcome = OUTCOME_LEAKED;
        emit VoteLeaked(_voteId, voterUniqueId, _outcome, msg.sender);
    }

    /**
    * @notice Reveal `_outcome` vote of `_voter` for vote #`_voteId`
    * @param _voteId ID of the vote instance to reveal a vote of
    * @param _voter Address of the voter to reveal a vote for
    * @param _outcome Outcome revealed by the voter
    * @param _salt Salt to decrypt and validate the committed vote of the voter
    */
    function reveal(uint256 _voteId, address _voter, uint8 _outcome, bytes32 _salt) external voteExists(_voteId) {
        address voterUniqueId = _voterUniqueId(_voter);
        Vote storage vote = voteRecords[_voteId];
        CastVote storage castVote = vote.votes[voterUniqueId];
        _checkValidSalt(castVote, _outcome, _salt);
        require(_isValidOutcome(vote, _outcome), ERROR_INVALID_OUTCOME);

        uint256 weight = _ensureVoterCanReveal(_voteId, voterUniqueId);

        castVote.outcome = _outcome;
        _updateTally(vote, _outcome, weight);
        emit VoteRevealed(_voteId, voterUniqueId, _outcome, msg.sender);
    }

    /**
    * @dev The user just verified themselves in the BrightIdRegister, claim on there behalf.
    * @param _voterSenderAddress The address from which the transaction was created
    * @param _voterUniqueId The unique address assigned to the registered BrightId user
    * @param _data Data used to determine what function to call, unused here
    */
    function receiveRegistration(address _voterSenderAddress, address _voterUniqueId, bytes calldata _data) external {
        require(msg.sender == address(_brightIdRegister()), ERROR_SENDER_NOT_BRIGHTID_REGISTER);

        if (_data.toBytes4() == CRVoting(this).commit.selector) {
            uint256 voteId = _data.toUint256(4); // voteIdLocation: 4 (from end of sig)
            bytes32 commitment = _data.toBytes32(36); // commitmentLocation: 4 + 32 = 36 (from end of sig + uint256 voteId)
            _commit(voteId, commitment, _voterUniqueId);
        } else {
            revert(ERROR_NO_FUNCTION_MATCH);
        }
    }

    /**
    * @dev Get the maximum allowed outcome for a given vote instance
    * @param _voteId ID of the vote instance querying the max allowed outcome of
    * @return Max allowed outcome for the given vote instance
    */
    function getMaxAllowedOutcome(uint256 _voteId) external view voteExists(_voteId) returns (uint8) {
        Vote storage vote = voteRecords[_voteId];
        return vote.maxAllowedOutcome;
    }

    /**
    * @dev Get the winning outcome of a vote instance. If the winning outcome is missing, which means no one voted in
    *      the given vote instance, it will be considered refused.
    * @param _voteId ID of the vote instance querying the winning outcome of
    * @return Winning outcome of the given vote instance or refused in case it's missing
    */
    function getWinningOutcome(uint256 _voteId) external view voteExists(_voteId) returns (uint8) {
        Vote storage vote = voteRecords[_voteId];
        uint8 winningOutcome = vote.winningOutcome;
        return winningOutcome == OUTCOME_MISSING ? OUTCOME_REFUSED : winningOutcome;
    }

    /**
    * @dev Get the tally of an outcome for a certain vote instance
    * @param _voteId ID of the vote instance querying the tally of
    * @param _outcome Outcome querying the tally of
    * @return Tally of the outcome being queried for the given vote instance
    */
    function getOutcomeTally(uint256 _voteId, uint8 _outcome) external view voteExists(_voteId) returns (uint256) {
        Vote storage vote = voteRecords[_voteId];
        return vote.outcomesTally[_outcome];
    }

    /**
    * @dev Tell whether an outcome is valid for a given vote instance or not. Missing and leaked outcomes are not considered
    *      valid. The only valid outcomes are refused or any of the custom outcomes of the given vote instance.
    * @param _voteId ID of the vote instance to check the outcome of
    * @param _outcome Outcome to check if valid or not
    * @return True if the given outcome is valid for the requested vote instance, false otherwise.
    */
    function isValidOutcome(uint256 _voteId, uint8 _outcome) external view voteExists(_voteId) returns (bool) {
        Vote storage vote = voteRecords[_voteId];
        return _isValidOutcome(vote, _outcome);
    }

    /**
    * @dev Get the outcome voted by a voter for a certain vote instance
    * @param _voteId ID of the vote instance querying the outcome of
    * @param _voter Address of the voter querying the outcome of
    * @return Outcome of the voter for the given vote instance
    */
    function getVoterOutcome(uint256 _voteId, address _voter) external view voteExists(_voteId) returns (uint8) {
        address voterUniqueId = _voterUniqueId(_voter);
        Vote storage vote = voteRecords[_voteId];
        return vote.votes[voterUniqueId].outcome;
    }

    /**
    * @dev Tell whether a voter voted in favor of a certain outcome in a vote instance or not.
    * @param _voteId ID of the vote instance to query if a voter voted in favor of a certain outcome
    * @param _outcome Outcome to query if the given voter voted in favor of
    * @param _voter Address of the voter to query if voted in favor of the given outcome
    * @return True if the given voter voted in favor of the given outcome, false otherwise
    */
    function hasVotedInFavorOf(uint256 _voteId, uint8 _outcome, address _voter) external view voteExists(_voteId) returns (bool) {
        address voterUniqueId = _voterUniqueId(_voter);
        Vote storage vote = voteRecords[_voteId];
        return vote.votes[voterUniqueId].outcome == _outcome;
    }

    /**
    * @dev Filter a list of voters based on whether they voted in favor of a certain outcome in a vote instance or not.
    *      Note that if there was no winning outcome, it means that no one voted, then all voters will be considered
    *      voting against any of the given outcomes.
    * @param _voteId ID of the vote instance to be checked
    * @param _outcome Outcome to filter the list of voters of
    * @param _voters List of addresses of the voters to be filtered
    * @return List of results to tell whether a voter voted in favor of the given outcome or not
    */
    function getVotersInFavorOf(uint256 _voteId, uint8 _outcome, address[] calldata _voters) external view voteExists(_voteId)
        returns (bool[] memory)
    {
        Vote storage vote = voteRecords[_voteId];
        bool[] memory votersInFavor = new bool[](_voters.length);

        // If there was a winning outcome, filter those voters that voted in favor of the given outcome.
        for (uint256 i = 0; i < _voters.length; i++) {
            address voterUniqueId = _voterUniqueId(_voters[i]);
            votersInFavor[i] = _outcome == vote.votes[voterUniqueId].outcome;
        }
        return votersInFavor;
    }

    /**
    * @dev Hash a vote outcome using a given salt
    * @param _outcome Outcome to be hashed
    * @param _salt Encryption salt
    * @return Hashed outcome
    */
    function hashVote(uint8 _outcome, bytes32 _salt) external pure returns (bytes32) {
        return _hashVote(_outcome, _salt);
    }

    /**
    * @notice Commit a vote for vote #`_voteId`
    * @param _voteId ID of the vote instance to commit a vote to
    * @param _commitment Hashed outcome to be stored for future reveal
    * @param _voterUniqueId Voter unique ID from the BrightIdRegister
    */
    function _commit(uint256 _voteId, bytes32 _commitment, address _voterUniqueId) internal voteExists(_voteId) {
        CastVote storage castVote = voteRecords[_voteId].votes[_voterUniqueId];
        require(castVote.commitment == bytes32(0), ERROR_VOTE_ALREADY_COMMITTED);
        _ensureVoterCanCommit(_voteId, _voterUniqueId);

        castVote.commitment = _commitment;
        emit VoteCommitted(_voteId, _voterUniqueId, _commitment);
    }

    /**
    * @dev Internal function to ensure votes can be committed for a vote
    * @param _voteId ID of the vote instance to be checked
    */
    function _ensureCanCommit(uint256 _voteId) internal {
        ICRVotingOwner owner = _votingOwner();
        owner.ensureCanCommit(_voteId);
    }

    /**
    * @dev Internal function to ensure a voter can commit votes
    * @param _voteId ID of the vote instance to be checked
    * @param _voter Address of the voter willing to commit a vote
    */
    function _ensureVoterCanCommit(uint256 _voteId, address _voter) internal {
        ICRVotingOwner owner = _votingOwner();
        owner.ensureCanCommit(_voteId, _voter);
    }

    /**
    * @dev Internal function to ensure a voter can reveal votes
    * @param _voteId ID of the vote instance to be checked
    * @param _voter Address of the voter willing to reveal a vote
    * @return Weight of the voter willing to reveal a vote
    */
    function _ensureVoterCanReveal(uint256 _voteId, address _voter) internal returns (uint256) {
        // There's no need to check voter weight, as this was done on commit
        ICRVotingOwner owner = _votingOwner();
        uint64 weight = owner.ensureCanReveal(_voteId, _voter);
        return uint256(weight);
    }

    /**
    * @dev Internal function to check if a vote can be revealed for the given outcome and salt
    * @param _castVote Cast vote to be revealed
    * @param _outcome Outcome of the cast vote to be proved
    * @param _salt Salt to decrypt and validate the provided outcome for a cast vote
    */
    function _checkValidSalt(CastVote storage _castVote, uint8 _outcome, bytes32 _salt) internal view {
        require(_castVote.outcome == OUTCOME_MISSING, ERROR_VOTE_ALREADY_REVEALED);
        require(_castVote.commitment == _hashVote(_outcome, _salt), ERROR_INVALID_COMMITMENT_SALT);
    }

    /**
    * @dev Internal function to tell whether a certain outcome is valid for a given vote instance or not. Note that
    *      the missing and leaked outcomes are not considered valid. The only outcomes considered valid are refused
    *      or any of the possible outcomes of the given vote instance. This function assumes the given vote exists.
    * @param _vote Vote instance to check the outcome of
    * @param _outcome Outcome to check if valid or not
    * @return True if the given outcome is valid for the requested vote instance, false otherwise.
    */
    function _isValidOutcome(Vote storage _vote, uint8 _outcome) internal view returns (bool) {
        return _outcome >= OUTCOME_REFUSED && _outcome <= _vote.maxAllowedOutcome;
    }

    /**
    * @dev Internal function to check if a vote instance was already created
    * @param _vote Vote instance to be checked
    * @return True if the given vote instance was already created, false otherwise
    */
    function _existsVote(Vote storage _vote) internal view returns (bool) {
        return _vote.maxAllowedOutcome != OUTCOME_MISSING;
    }

    /**
    * @dev Internal function to hash a vote outcome using a given salt
    * @param _outcome Outcome to be hashed
    * @param _salt Encryption salt
    * @return Hashed outcome
    */
    function _hashVote(uint8 _outcome, bytes32 _salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_outcome, _salt));
    }

    /**
    * @dev Private function to update the tally of a given vote instance based on a new weight in favor of an outcome.
    *      This function assumes the vote instance exists.
    * @param _vote Vote instance to update the tally of
    * @param _outcome Outcome of the vote instance to update the tally of
    * @param _weight Weight to be added to the given outcome of the vote instance
    */
    function _updateTally(Vote storage _vote, uint8 _outcome, uint256 _weight) private {
        // Check if the given outcome is valid. Missing and leaked votes are ignored for the tally.
        if (!_isValidOutcome(_vote, _outcome)) {
            return;
        }

        uint256 newOutcomeTally = _vote.outcomesTally[_outcome].add(_weight);
        _vote.outcomesTally[_outcome] = newOutcomeTally;

        // Update the winning outcome only if its support was passed or if the given outcome represents a lowest
        // option than the winning outcome in case of a tie.
        uint8 winningOutcome = _vote.winningOutcome;
        uint256 winningOutcomeTally = _vote.outcomesTally[winningOutcome];
        if (newOutcomeTally > winningOutcomeTally || (newOutcomeTally == winningOutcomeTally && _outcome < winningOutcome)) {
            _vote.winningOutcome = _outcome;
        }
    }

    /**
    * @dev Function to convert a voters sender address to their unique voter address
    */
    function _voterUniqueId(address _voterSenderAddress) internal view returns (address) {
        return _brightIdRegister().uniqueUserId(_voterSenderAddress);
    }
}
