pragma solidity ^0.5.10;

import '../../../../1_gelato_standards/3_GTA_standards/gelato_trigger_standards/GelatoTriggersStandard.sol';

contract TriggerTimestampPassed is GelatoTriggersStandard {

    constructor(address payable _gelatoCore,
                string memory _triggerSignature
    )
        public
        GelatoTriggersStandard(_gelatoCore, _triggerSignature)
    {}

    function fired(uint256 _timestamp)
        public
        view
        returns(bool)
    {
        return _timestamp <= block.timestamp;
    }

    function getLatestTimestamp()
        public
        view
        returns(uint256)
    {
        return block.timestamp;
    }

}