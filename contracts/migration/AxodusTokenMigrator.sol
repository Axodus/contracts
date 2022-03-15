// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.7.5;

import "../interfaces/IERC20.sol";
import "../interfaces/IsAXDS.sol";
import "../interfaces/IwsAXDS.sol";
import "../interfaces/IgAXDS.sol";
import "../interfaces/ITreasury.sol";
import "../interfaces/IStaking.sol";
import "../interfaces/IOwnable.sol";
import "../interfaces/IUniswapV2Router.sol";
import "../interfaces/IStakingV1.sol";
import "../interfaces/ITreasuryV1.sol";

import "../types/AxodusAccessControlled.sol";

import "../libraries/SafeMath.sol";
import "../libraries/SafeERC20.sol";

contract AxodusTokenMigrator is AxodusAccessControlled {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IgAXDS;
    using SafeERC20 for IsAXDS;
    using SafeERC20 for IwsAXDS;

    /* ========== MIGRATION ========== */

    event TimelockStarted(uint256 block, uint256 end);
    event Migrated(address staking, address treasury);
    event Funded(uint256 amount);
    event Defunded(uint256 amount);

    /* ========== STATE VARIABLES ========== */

    IERC20 public immutable oldAXDS;
    IsAXDS public immutable oldsAXDS;
    IwsAXDS public immutable oldwsAXDS;
    ITreasuryV1 public immutable oldTreasury;
    IStakingV1 public immutable oldStaking;

    IUniswapV2Router public immutable sushiRouter;
    IUniswapV2Router public immutable uniRouter;

    IgAXDS public gAXDS;
    ITreasury public newTreasury;
    IStaking public newStaking;
    IERC20 public newAXDS;

    bool public axdsMigrated;
    bool public shutdown;

    uint256 public immutable timelockLength;
    uint256 public timelockEnd;

    uint256 public oldSupply;

    constructor(
        address _oldAXDS,
        address _oldsAXDS,
        address _oldTreasury,
        address _oldStaking,
        address _oldwsAXDS,
        address _sushi,
        address _uni,
        uint256 _timelock,
        address _authority
    ) AxodusAccessControlled(IAxodusAuthority(_authority)) {
        require(_oldAXDS != address(0), "Zero address: AXDS");
        oldAXDS = IERC20(_oldAXDS);
        require(_oldsAXDS != address(0), "Zero address: sAXDS");
        oldsAXDS = IsAXDS(_oldsAXDS);
        require(_oldTreasury != address(0), "Zero address: Treasury");
        oldTreasury = ITreasuryV1(_oldTreasury);
        require(_oldStaking != address(0), "Zero address: Staking");
        oldStaking = IStakingV1(_oldStaking);
        require(_oldwsAXDS != address(0), "Zero address: wsAXDS");
        oldwsAXDS = IwsAXDS(_oldwsAXDS);
        require(_sushi != address(0), "Zero address: Sushi");
        sushiRouter = IUniswapV2Router(_sushi);
        require(_uni != address(0), "Zero address: Uni");
        uniRouter = IUniswapV2Router(_uni);
        timelockLength = _timelock;
    }

    /* ========== MIGRATION ========== */

    enum TYPE {
        UNSTAKED,
        STAKED,
        WRAPPED
    }

    // migrate AXDSv1, sAXDSv1, or wsAXDS for AXDSv2, sAXDSv2, or gAXDS
    function migrate(
        uint256 _amount,
        TYPE _from,
        TYPE _to
    ) external {
        require(!shutdown, "Shut down");

        uint256 wAmount = oldwsAXDS.sAXDSTowAXDS(_amount);

        if (_from == TYPE.UNSTAKED) {
            require(axdsMigrated, "Only staked until migration");
            oldAXDS.safeTransferFrom(msg.sender, address(this), _amount);
        } else if (_from == TYPE.STAKED) {
            oldsAXDS.safeTransferFrom(msg.sender, address(this), _amount);
        } else {
            oldwsAXDS.safeTransferFrom(msg.sender, address(this), _amount);
            wAmount = _amount;
        }

        if (axdsMigrated) {
            require(oldSupply >= oldAXDS.totalSupply(), "AXDSv1 minted");
            _send(wAmount, _to);
        } else {
            gAXDS.mint(msg.sender, wAmount);
        }
    }

    // migrate all olympus tokens held
    function migrateAll(TYPE _to) external {
        require(!shutdown, "Shut down");

        uint256 axdsBal = 0;
        uint256 sAXDSBal = oldsAXDS.balanceOf(msg.sender);
        uint256 wsAXDSBal = oldwsAXDS.balanceOf(msg.sender);

        if (oldAXDS.balanceOf(msg.sender) > 0 && axdsMigrated) {
            axdsBal = oldAXDS.balanceOf(msg.sender);
            oldAXDS.safeTransferFrom(msg.sender, address(this), axdsBal);
        }
        if (sAXDSBal > 0) {
            oldsAXDS.safeTransferFrom(msg.sender, address(this), sAXDSBal);
        }
        if (wsAXDSBal > 0) {
            oldwsAXDS.safeTransferFrom(msg.sender, address(this), wsAXDSBal);
        }

        uint256 wAmount = wsAXDSBal.add(oldwsAXDS.sAXDSTowAXDS(axdsBal.add(sAXDSBal)));
        if (axdsMigrated) {
            require(oldSupply >= oldAXDS.totalSupply(), "AXDSv1 minted");
            _send(wAmount, _to);
        } else {
            gAXDS.mint(msg.sender, wAmount);
        }
    }

    // send preferred token
    function _send(uint256 wAmount, TYPE _to) internal {
        if (_to == TYPE.WRAPPED) {
            gAXDS.safeTransfer(msg.sender, wAmount);
        } else if (_to == TYPE.STAKED) {
            newStaking.unwrap(msg.sender, wAmount);
        } else if (_to == TYPE.UNSTAKED) {
            newStaking.unstake(msg.sender, wAmount, false, false);
        }
    }

    // bridge back to AXDS, sAXDS, or wsAXDS
    function bridgeBack(uint256 _amount, TYPE _to) external {
        if (!axdsMigrated) {
            gAXDS.burn(msg.sender, _amount);
        } else {
            gAXDS.safeTransferFrom(msg.sender, address(this), _amount);
        }

        uint256 amount = oldwsAXDS.wAXDSTosAXDS(_amount);
        // error throws if contract does not have enough of type to send
        if (_to == TYPE.UNSTAKED) {
            oldAXDS.safeTransfer(msg.sender, amount);
        } else if (_to == TYPE.STAKED) {
            oldsAXDS.safeTransfer(msg.sender, amount);
        } else if (_to == TYPE.WRAPPED) {
            oldwsAXDS.safeTransfer(msg.sender, _amount);
        }
    }

    /* ========== OWNABLE ========== */

    // halt migrations (but not bridging back)
    function halt() external onlyPolicy {
        require(!axdsMigrated, "Migration has occurred");
        shutdown = !shutdown;
    }

    // withdraw backing of migrated AXDS
    function defund(address reserve) external onlyGovernor {
        require(axdsMigrated, "Migration has not begun");
        require(timelockEnd < block.number && timelockEnd != 0, "Timelock not complete");

        oldwsAXDS.unwrap(oldwsAXDS.balanceOf(address(this)));

        uint256 amountToUnstake = oldsAXDS.balanceOf(address(this));
        oldsAXDS.approve(address(oldStaking), amountToUnstake);
        oldStaking.unstake(amountToUnstake, false);

        uint256 balance = oldAXDS.balanceOf(address(this));

        if (balance > oldSupply) {
            oldSupply = 0;
        } else {
            oldSupply -= balance;
        }

        uint256 amountToWithdraw = balance.mul(1e9);
        oldAXDS.approve(address(oldTreasury), amountToWithdraw);
        oldTreasury.withdraw(amountToWithdraw, reserve);
        IERC20(reserve).safeTransfer(address(newTreasury), IERC20(reserve).balanceOf(address(this)));

        emit Defunded(balance);
    }

    // start timelock to send backing to new treasury
    function startTimelock() external onlyGovernor {
        require(timelockEnd == 0, "Timelock set");
        timelockEnd = block.number.add(timelockLength);

        emit TimelockStarted(block.number, timelockEnd);
    }

    // set gAXDS address
    function setgAXDS(address _gAXDS) external onlyGovernor {
        require(address(gAXDS) == address(0), "Already set");
        require(_gAXDS != address(0), "Zero address: gAXDS");

        gAXDS = IgAXDS(_gAXDS);
    }

    // call internal migrate token function
    function migrateToken(address token) external onlyGovernor {
        _migrateToken(token, false);
    }

    /**
     *   @notice Migrate LP and pair with new AXDS
     */
    function migrateLP(
        address pair,
        bool sushi,
        address token,
        uint256 _minA,
        uint256 _minB
    ) external onlyGovernor {
        uint256 oldLPAmount = IERC20(pair).balanceOf(address(oldTreasury));
        oldTreasury.manage(pair, oldLPAmount);

        IUniswapV2Router router = sushiRouter;
        if (!sushi) {
            router = uniRouter;
        }

        IERC20(pair).approve(address(router), oldLPAmount);
        (uint256 amountA, uint256 amountB) = router.removeLiquidity(
            token,
            address(oldAXDS),
            oldLPAmount,
            _minA,
            _minB,
            address(this),
            block.timestamp
        );

        newTreasury.mint(address(this), amountB);

        IERC20(token).approve(address(router), amountA);
        newAXDS.approve(address(router), amountB);

        router.addLiquidity(
            token,
            address(newAXDS),
            amountA,
            amountB,
            amountA,
            amountB,
            address(newTreasury),
            block.timestamp
        );
    }

    // Failsafe function to allow owner to withdraw funds sent directly to contract in case someone sends non-axds tokens to the contract
    function withdrawToken(
        address tokenAddress,
        uint256 amount,
        address recipient
    ) external onlyGovernor {
        require(tokenAddress != address(0), "Token address cannot be 0x0");
        require(tokenAddress != address(gAXDS), "Cannot withdraw: gAXDS");
        require(tokenAddress != address(oldAXDS), "Cannot withdraw: old-AXDS");
        require(tokenAddress != address(oldsAXDS), "Cannot withdraw: old-sAXDS");
        require(tokenAddress != address(oldwsAXDS), "Cannot withdraw: old-wsAXDS");
        require(amount > 0, "Withdraw value must be greater than 0");
        if (recipient == address(0)) {
            recipient = msg.sender; // if no address is specified the value will will be withdrawn to Owner
        }

        IERC20 tokenContract = IERC20(tokenAddress);
        uint256 contractBalance = tokenContract.balanceOf(address(this));
        if (amount > contractBalance) {
            amount = contractBalance; // set the withdrawal amount equal to balance within the account.
        }
        // transfer the token from address of this contract
        tokenContract.safeTransfer(recipient, amount);
    }

    // migrate contracts
    function migrateContracts(
        address _newTreasury,
        address _newStaking,
        address _newAXDS,
        address _newsAXDS,
        address _reserve
    ) external onlyGovernor {
        require(!axdsMigrated, "Already migrated");
        axdsMigrated = true;
        shutdown = false;

        require(_newTreasury != address(0), "Zero address: Treasury");
        newTreasury = ITreasury(_newTreasury);
        require(_newStaking != address(0), "Zero address: Staking");
        newStaking = IStaking(_newStaking);
        require(_newAXDS != address(0), "Zero address: AXDS");
        newAXDS = IERC20(_newAXDS);

        oldSupply = oldAXDS.totalSupply(); // log total supply at time of migration

        gAXDS.migrate(_newStaking, _newsAXDS); // change gAXDS minter

        _migrateToken(_reserve, true); // will deposit tokens into new treasury so reserves can be accounted for

        _fund(oldsAXDS.circulatingSupply()); // fund with current staked supply for token migration

        emit Migrated(_newStaking, _newTreasury);
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    // fund contract with gAXDS
    function _fund(uint256 _amount) internal {
        newTreasury.mint(address(this), _amount);
        newAXDS.approve(address(newStaking), _amount);
        newStaking.stake(address(this), _amount, false, true); // stake and claim gAXDS

        emit Funded(_amount);
    }

    /**
     *   @notice Migrate token from old treasury to new treasury
     */
    function _migrateToken(address token, bool deposit) internal {
        uint256 balance = IERC20(token).balanceOf(address(oldTreasury));

        uint256 excessReserves = oldTreasury.excessReserves();
        uint256 tokenValue = oldTreasury.valueOf(token, balance);

        if (tokenValue > excessReserves) {
            tokenValue = excessReserves;
            balance = excessReserves * 10**9;
        }

        oldTreasury.manage(token, balance);

        if (deposit) {
            IERC20(token).safeApprove(address(newTreasury), balance);
            newTreasury.deposit(balance, token, tokenValue);
        } else {
            IERC20(token).safeTransfer(address(newTreasury), balance);
        }
    }
}
