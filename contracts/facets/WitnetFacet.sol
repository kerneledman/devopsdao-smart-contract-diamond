// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "witnet-solidity-bridge/contracts/UsingWitnet.sol";
import "witnet-solidity-bridge/contracts/libs/Witnet.sol";
import "../libraries/LibWitnetFacet.sol";
import "../libraries/LibTasks.sol";
import "../contracts/TaskContract.sol";

import "../libraries/LibUtils.sol";


contract WitnetFacet
    is
        UsingWitnet
{
    using Witnet for Witnet.Result;

    using LibWitnetFacet for WitnetRequestBoard;
    using LibWitnetFacet for WitnetRequestTemplate;

    event NewRadonRequestHash(bytes32 hash);

    WitnetRequestTemplate public immutable witnetRequestTemplate;

    constructor(
            WitnetRequestBoard _witnetRequestBoard,
            WitnetRequestTemplate _witnetRequestTemplate,
            WitnetV2.RadonSLA memory _witnetRadonSLA
        )
        UsingWitnet(_witnetRequestBoard)
    {
        require(
            address(_witnetRequestTemplate).code.length > 0
                // && _witnetRequestTemplate.class() == type(WitnetRequestTemplate).interfaceId
                && _witnetRequestTemplate.getRadonRetrievalsCount() == 1
                && _witnetRequestTemplate.parameterized()
                && _witnetRequestTemplate.resultDataType() == WitnetV2.RadonDataTypes.String
            , "WitnetFacet: uncompliant WitnetRequestTemplate"
        );
        witnetRequestTemplate = _witnetRequestTemplate;
        __storage().slaHash = witnetRequestTemplate.registry().verifyRadonSLA(_witnetRadonSLA);
    }

    function checkResultAvailability(address taskAddress) external view returns (bool) {
        return _checkResultAvailability(taskAddress);
    }

    function getLastWitnetQuery(address taskAddress) external view returns (Witnet.Query memory) {
        return witnet.getQueryData(__storage().queries[taskAddress].id);
    }

    function getLastWitnetResult(address taskAddress) external view returns (Witnet.Result memory) {
        return witnet.readResponseResult(__storage().queries[taskAddress].id);
    }

    function getLastResult(address taskAddress) public view returns (LibWitnetFacet.Result memory _result) {
        uint _queryId = __storage().queries[taskAddress].id;
        Witnet.ResultStatus _status = witnet.checkResultStatus(_queryId);
        if (_status == Witnet.ResultStatus.Ready) {
            Witnet.Result memory _witnetResult = witnet.readResponseResult(_queryId);
            _result = LibWitnetFacet.Result({
                failed: false,
                pendingMerge: false,
                status: _witnetResult.asText()
            });
        } else if (_status == Witnet.ResultStatus.Error) {
            Witnet.ResultError memory _witnetError = witnet.checkResultError(_queryId);
            if (_witnetError.code == Witnet.ResultErrorCodes.MapKeyNotFound) {
                _result = LibWitnetFacet.Result({
                    failed: false,
                    pendingMerge: true,
                    status: "(unmerged)"
                });
            } else {
                _result = LibWitnetFacet.Result({
                    failed: true,
                    pendingMerge: false,
                    status: _witnetError.reason
                });
            }
        }
    }

    function saveSuccessfulResult(address taskAddress) public {
            LibWitnetFacet.Result memory _result = getLastResult(taskAddress);
            if(keccak256(bytes(_result.status)) == keccak256("closed")){
                Task memory task = TaskContract(payable(taskAddress)).getTaskData();
                TaskContract(payable(taskAddress)).taskStateChange(task.contractOwner, task.participant, TASK_STATE_COMPLETED, 'automatically accepting based on PR merge', 0, 5);
            }
            else{
                revert('PR not merged');
            }
    }

    function postRequest(address taskAddress)
        public payable
        returns (uint256 _queryId)
    {   
        Task memory task = TaskContract(payable(taskAddress)).getTaskData();

        LibWitnetFacet.Args memory args;
        args.subpath = task.repository;
        // args.title = string.concat("dodao.dev/#/tasks/",LibUtils.addressToString(taskAddress), " task: ", task.title);
        args.title = string.concat("dodao.dev/#/tasks/",LibUtils.addressToString(taskAddress));

        return _postRequest(taskAddress, args);
    }

    function postRequestTest(address taskAddress, LibWitnetFacet.Args memory _args)
        public payable
        returns (uint256 _queryId)
    {
        return _postRequest(taskAddress, _args);
    }

    function postRequest(address taskAddress, bytes32 _radHash)
        public payable
        returns (uint256 _queryId)
    {
        return _postRequest(taskAddress, _radHash);
    }

    function updateRadonSLA(bytes32 slaHash) external {
        LibWitnetFacet.Storage storage _storage = LibWitnetFacet.witnetFacetStorage();
        _storage.slaHash = slaHash;
        // __storage().slaHash = slaHash;
    }

    function witnetRadonSLA() external view returns (WitnetV2.RadonSLA memory) {
        return witnetRequestTemplate.registry().lookupRadonSLA(__storage().slaHash);
    }


    // ================================================================================================================
    // --- Internal methods -------------------------------------------------------------------------------------------

    function _checkResultAvailability(address taskAddress)
        internal view
        returns (bool)
    {
        uint256 _queryId = __storage().queries[taskAddress].id;
        return (
            _queryId > 0
                && _witnetCheckResultAvailability(_queryId)
        );
    }

    function _postRequest(address taskAddress, LibWitnetFacet.Args memory _args)
        internal
        returns (uint256 _queryId)
    {
        bytes32 _radHash = witnetRequestTemplate.verifyRadonRequest(_args);
        emit NewRadonRequestHash(_radHash);
        return _postRequest(taskAddress, _radHash);
    }

    function _postRequest(address taskAddress, bytes32 _witnetRadHash)
        internal
        returns (uint256 _queryId)
    {
        LibWitnetFacet.Query storage __query = __storage().queries[taskAddress];
        _queryId = __query.id;
        uint _usedFunds;
        if (_queryId == 0) {
            // First attempt: request to the WRB
            (_queryId, _usedFunds) = _witnetPostRequest(_witnetRadHash, __storage().slaHash );
            __query.id = _queryId;
            __query.radHash = _witnetRadHash;
        } else {
            require(
                _witnetRadHash == __query.radHash,
                "WitnetFacet: radHash mistmatch"
            );
            if (!_witnetCheckResultAvailability(_queryId)) {
                // upgrade the reward if the query was not over yet:
                _usedFunds = _witnetUpgradeReward(_queryId);
            } else {
                // if last attempt is solved but result is not yet final...
                LibWitnetFacet.Result memory _lastResult = getLastResult(taskAddress);
                if (
                    _lastResult.failed == false
                        && _lastResult.pendingMerge == false 
                        && keccak256(bytes(_lastResult.status)) == keccak256(bytes("closed"))
                ) {
                    revert("WitnetFacet: cannot update final result");
                }
                // ...launch new query:
                (_queryId, _usedFunds) = _witnetPostRequest(_witnetRadHash, __storage().slaHash);
                __query.id = _queryId;
            }
        }
        // transfer back unused funds
        if (_usedFunds < msg.value) {
            payable(msg.sender).transfer(msg.value - _usedFunds);
        }
    }

    function __storage() internal pure returns (LibWitnetFacet.Storage storage) {
        return LibWitnetFacet.witnetFacetStorage();
    }
}