// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IDep {
    function registerTask(
        address contractAddress,
        bytes calldata execData
    ) external returns (bytes32 taskId);
    function cancelTask(bytes32 taskId) external;
}

contract AutomatedWorkflow {
    using SafeERC20 for IERC20;

    struct Workflow {
        address owner;
        address destination;
        bytes execData;
        uint256 maxGasLimit;
        uint256 prefund;
        uint256 timestamp;
        bool active;
    }

    IDep private _dep;
    mapping(uint256 => Workflow) private workflows;
    uint256 private workflowCount;
    address private _owner;

    event WorkflowRegistered(uint256 indexed workflowId, address indexed owner);
    event WorkflowExecuted(uint256 indexed workflowId, uint256 timestamp);
    event PrefundWithdrawn(uint256 indexed workflowId, uint256 amount);

    constructor(IDep dep) {
        _dep = dep;
        _owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == _owner, "Not the owner");
        _;
    }

    modifier onlyWorkflowOwner(uint256 workflowId) {
        require(
            workflows[workflowId].owner == msg.sender,
            "Not the workflow owner"
        );
        _;
    }

    modifier onlyActiveWorkflow(uint256 workflowId) {
        require(workflows[workflowId].active, "Workflow is not active");
        _;
    }

    function registerWorkflow(
        address destination,
        bytes calldata data
    ) external {
        workflowCount++;
        workflows[workflowCount] = Workflow({
            owner: msg.sender,
            destination: destination,
            execData: data,
            maxGasLimit: 0,
            prefund: 0,
            timestamp: 0,
            active: false
        });

        emit WorkflowRegistered(workflowCount, msg.sender);
    }

    function activateWorkflow(
        uint256 workflowId,
        uint256 maxGasLimit
    ) external onlyOwner {
        workflows[workflowId].maxGasLimit = maxGasLimit;
        workflows[workflowId].timestamp = block.timestamp;
        workflows[workflowId].active = true;
    }

    function prefundAndRun(
        uint256 workflowId
    )
        external
        payable
        onlyActiveWorkflow(workflowId)
        onlyWorkflowOwner(workflowId)
    {
        uint256 requiredPrefund = workflows[workflowId].maxGasLimit *
            tx.gasprice;
        require(msg.value >= requiredPrefund, "Insufficient prefund amount");

        workflows[workflowId].prefund += msg.value;
        require(
            block.timestamp >= workflows[workflowId].timestamp + 1 days,
            "Too soon to run the workflow"
        );

        uint256 initialGas = gasleft();
        workflows[workflowId].timestamp = block.timestamp;

        (bool success, ) = workflows[workflowId].destination.call(
            workflows[workflowId].execData
        );
        require(success, "Execution failed");

        uint256 gasUsed = initialGas - gasleft();
        uint256 gasCost = gasUsed * tx.gasprice;
        require(
            gasCost <= workflows[workflowId].prefund,
            "Gas cost exceeds prefund"
        );

        workflows[workflowId].prefund -= gasCost;
        payable(msg.sender).transfer(gasCost);

        emit WorkflowExecuted(workflowId, block.timestamp);
    }

    function cancelTask(uint256 workflowId) external onlyOwner {
        workflows[workflowId].active = false;
    }

    function setDEPAddress(IDep dep) external onlyOwner {
        _dep = dep;
    }

    function withdrawPrefund(
        uint256 workflowId,
        uint256 amount
    ) external onlyWorkflowOwner(workflowId) {
        require(
            workflows[workflowId].prefund >= amount,
            "Insufficient prefund"
        );

        workflows[workflowId].prefund -= amount;
        payable(msg.sender).transfer(amount);

        emit PrefundWithdrawn(workflowId, amount);
    }

    receive() external payable {}

    function withdraw(uint256 amount) external onlyOwner {
        require(address(this).balance >= amount, "Insufficient balance");
        payable(_owner).transfer(amount);
    }
}
