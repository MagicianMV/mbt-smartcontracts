// SPDX-License-Identifier: MIT

pragma solidity =0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../libraries/DecimalMath.sol";
import "../interfaces/IMagicBallToken.sol";

contract vMBTToken is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // ============ Storage(ERC20) ============

    string public name = "vMBT Membership Token";
    string public symbol = "vMBT";
    uint8 public decimals = 18;

    uint256 public _MIN_PENALTY_RATIO_ = 15 * 10**16; // 15%
    uint256 public _MAX_PENALTY_RATIO_ = 80 * 10**16; // 80%
    uint256 public _MIN_MINT_RATIO_ = 10 * 10**16; //10%
    uint256 public _MAX_MINT_RATIO_ = 80 * 10**16; //80%

    mapping(address => mapping(address => uint256)) internal _allowed;

    // ============ Storage ============

    address public _mbtToken;
    address public _mbtTeam;
    address public _mbtReserve;

    bool public _canTransfer;

    // staking reward parameters
    uint256 public _mbtPerBlock;
    uint256 public constant _superiorRatio = 10**17; // 0.1
    uint256 public constant _mbtRatio = 100; // 100
    uint256 public _mbtFeeBurnRatio = 30 * 10**16; //30%
    uint256 public _mbtFeeReserveRatio = 20 * 10**16; //20%

    // accounting
    uint112 public alpha = 10**18; // 1
    uint112 public _totalBlockDistribution;
    uint32 public _lastRewardBlock;

    uint256 public _totalBlockReward;
    uint256 public _totalStakingPower;
    mapping(address => UserInfo) public userInfo;
    
    uint256 public _superiorMinMBT = 1000e18; //The superior must obtain the min MBT that should be pledged for invitation rewards

    struct UserInfo {
        uint128 stakingPower;
        uint128 superiorSP;
        address superior;
        uint256 credit;
        uint256 creditDebt;
    }

    // ============ Events ============

    event MintVMBT(address user, address superior, uint256 mintMBT);
    event RedeemVMBT(address user, uint256 receiveMBT, uint256 burnMBT, uint256 feeMBT, uint256 reserveMBT);
    event DonateMBT(address user, uint256 donateMBT);
    event SetCanTransfer(bool allowed);

    event PreDeposit(uint256 mbtAmount);
    event ChangePerReward(uint256 mbtPerBlock);
    event UpdateMBTFeeBurnRatio(uint256 mbtFeeBurnRatio);

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    // ============ Modifiers ============

    modifier canTransfer() {
        require(_canTransfer, "vMBTToken: not allowed transfer");
        _;
    }

    modifier balanceEnough(address account, uint256 amount) {
        require(availableBalanceOf(account) >= amount, "vMBTToken: available amount not enough");
        _;
    }

    // ============ Constructor ============

    constructor(
        address mbtToken,
        address mbtTeam,
        address mbtReserve
    ) public {
        _mbtToken = mbtToken;
        _mbtTeam = mbtTeam;
        _mbtReserve = mbtReserve;

        changePerReward(15*10**18);
    }

    // ============ Ownable Functions ============`

    function setCanTransfer(bool allowed) public onlyOwner {
        _canTransfer = allowed;
        emit SetCanTransfer(allowed);
    }

    function changePerReward(uint256 mbtPerBlock) public onlyOwner {
        _updateAlpha();
        _mbtPerBlock = mbtPerBlock;
        emit ChangePerReward(mbtPerBlock);
    }

    function updateMBTFeeBurnRatio(uint256 mbtFeeBurnRatio) public onlyOwner {
        _mbtFeeBurnRatio = mbtFeeBurnRatio;
        emit UpdateMBTFeeBurnRatio(_mbtFeeBurnRatio);
    }

    function updateMBTFeeReserveRatio(uint256 mbtFeeReserve) public onlyOwner {
        _mbtFeeReserveRatio = mbtFeeReserve;
    }

    function updateTeamAddress(address team) public onlyOwner {
        _mbtTeam = team;
    }

    function updateReserveAddress(address newAddress) public onlyOwner {
        _mbtReserve = newAddress;
    }
    
    function setSuperiorMinMBT(uint256 val) public onlyOwner {
        _superiorMinMBT = val;
    }

    function emergencyWithdraw() public onlyOwner {
        uint256 mbtBalance = IERC20(_mbtToken).balanceOf(address(this));
        IERC20(_mbtToken).safeTransfer(owner(), mbtBalance);
    }

    // ============ Mint & Redeem & Donate ============

    function mint(uint256 mbtAmount, address superiorAddress) public {
        require(
            superiorAddress != address(0) && superiorAddress != msg.sender,
            "vMBTToken: Superior INVALID"
        );
        require(mbtAmount >= 1e18, "vMBTToken: must mint greater than 1");
        

        UserInfo storage user = userInfo[msg.sender];

        if (user.superior == address(0)) {
            require(
                superiorAddress == _mbtTeam || userInfo[superiorAddress].superior != address(0),
                "vMBTToken: INVALID_SUPERIOR_ADDRESS"
            );
            user.superior = superiorAddress;
        }
        
        if(_superiorMinMBT > 0) {
            uint256 curMBT = mbtBalanceOf(user.superior);
            if(curMBT < _superiorMinMBT) {
                user.superior = _mbtTeam;
            }
        }

        _updateAlpha();

        IERC20(_mbtToken).safeTransferFrom(msg.sender, address(this), mbtAmount);

        uint256 newStakingPower = DecimalMath.divFloor(mbtAmount, alpha);

        _mint(user, newStakingPower);

        emit MintVMBT(msg.sender, superiorAddress, mbtAmount);
    }

    function redeem(uint256 vMbtAmount, bool all) public balanceEnough(msg.sender, vMbtAmount) {
        _updateAlpha();
        UserInfo storage user = userInfo[msg.sender];

        uint256 mbtAmount;
        uint256 stakingPower;

        if (all) {
            stakingPower = uint256(user.stakingPower).sub(DecimalMath.divFloor(user.credit, alpha));
            mbtAmount = DecimalMath.mulFloor(stakingPower, alpha);
        } else {
            mbtAmount = vMbtAmount.mul(_mbtRatio);
            stakingPower = DecimalMath.divFloor(mbtAmount, alpha);
        }

        _redeem(user, stakingPower);

        (uint256 mbtReceive, uint256 burnMbtAmount, uint256 withdrawFeeAmount, uint256 reserveAmount) = getWithdrawResult(mbtAmount);

        IERC20(_mbtToken).safeTransfer(msg.sender, mbtReceive);

        if (burnMbtAmount > 0) {
            IMagicBallToken(_mbtToken).burn(burnMbtAmount);
        }
        if (reserveAmount > 0) {
            IERC20(_mbtToken).safeTransfer(_mbtReserve, reserveAmount);
        }

        if (withdrawFeeAmount > 0) {
            alpha = uint112(
                uint256(alpha).add(
                    DecimalMath.divFloor(withdrawFeeAmount, _totalStakingPower)
                )
            );
        }

        emit RedeemVMBT(msg.sender, mbtReceive, burnMbtAmount, withdrawFeeAmount, reserveAmount);
    }

    function donate(uint256 mbtAmount) public {

        IERC20(_mbtToken).safeTransferFrom(msg.sender, address(this), mbtAmount);

        alpha = uint112(
            uint256(alpha).add(DecimalMath.divFloor(mbtAmount, _totalStakingPower))
        );
        emit DonateMBT(msg.sender, mbtAmount);
    }

    // ============ ERC20 Functions ============

    function totalSupply() public view returns (uint256 vMbtSupply) {
        uint256 totalMbt = IERC20(_mbtToken).balanceOf(address(this));
        (,uint256 curDistribution) = getLatestAlpha();
        
        uint256 actualMbt = totalMbt.add(curDistribution);
        vMbtSupply = actualMbt / _mbtRatio;
    }

    function balanceOf(address account) public view returns (uint256 vMbtAmount) {
        vMbtAmount = mbtBalanceOf(account) / _mbtRatio;
    }

    function transfer(address to, uint256 vMbtAmount) public returns (bool) {
        _updateAlpha();
        _transfer(msg.sender, to, vMbtAmount);
        return true;
    }

    function approve(address spender, uint256 vMbtAmount) canTransfer public returns (bool) {
        _allowed[msg.sender][spender] = vMbtAmount;
        emit Approval(msg.sender, spender, vMbtAmount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 vMbtAmount
    ) public returns (bool) {
        require(vMbtAmount <= _allowed[from][msg.sender], "ALLOWANCE_NOT_ENOUGH");
        _updateAlpha();
        _transfer(from, to, vMbtAmount);
        _allowed[from][msg.sender] = _allowed[from][msg.sender].sub(vMbtAmount);
        return true;
    }

    function allowance(address owner, address spender) public view returns (uint256) {
        return _allowed[owner][spender];
    }

    // ============ Helper Functions ============

    function getLatestAlpha() public view returns (uint256 newAlpha, uint256 curDistribution) {
        if (_lastRewardBlock == 0) {
            curDistribution = 0;
        } else {
            curDistribution = _mbtPerBlock * (block.number - _lastRewardBlock);
        }
        if (_totalStakingPower > 0) {
            newAlpha = uint256(alpha).add(DecimalMath.divFloor(curDistribution, _totalStakingPower));
        } else {
            newAlpha = alpha;
        }
    }

    function availableBalanceOf(address account) public view returns (uint256 vMbtAmount) {
        vMbtAmount = balanceOf(account);
    }

    function mbtBalanceOf(address account) public view returns (uint256 mbtAmount) {
        UserInfo memory user = userInfo[account];
        (uint256 newAlpha,) = getLatestAlpha();
        uint256 nominalMbt =  DecimalMath.mulFloor(uint256(user.stakingPower), newAlpha);
        if(nominalMbt > user.credit) {
            mbtAmount = nominalMbt - user.credit;
        } else {
            mbtAmount = 0;
        }
    }

    function getWithdrawResult(uint256 mbtAmount)
    public
    view
    returns (
        uint256 mbtReceive,
        uint256 burnMbtAmount,
        uint256 withdrawFeeMbtAmount,
        uint256 reserveMbtAmount
    )
    {
        uint256 feeRatio = getMbtWithdrawFeeRatio();

        withdrawFeeMbtAmount = DecimalMath.mulFloor(mbtAmount, feeRatio);
        mbtReceive = mbtAmount.sub(withdrawFeeMbtAmount);

        burnMbtAmount = DecimalMath.mulFloor(withdrawFeeMbtAmount, _mbtFeeBurnRatio);
        reserveMbtAmount = DecimalMath.mulFloor(withdrawFeeMbtAmount, _mbtFeeReserveRatio);

        withdrawFeeMbtAmount = withdrawFeeMbtAmount.sub(burnMbtAmount);
        withdrawFeeMbtAmount = withdrawFeeMbtAmount.sub(reserveMbtAmount);
    }

    function getMbtWithdrawFeeRatio() public view returns (uint256 feeRatio) {
        uint256 mbtCirculationAmount = getCirculationSupply();

        uint256 x =
        DecimalMath.divCeil(
            totalSupply() * 100,
            mbtCirculationAmount
        );

        feeRatio = getRatioValue(x);
    }

    function setRatioValue(uint256 min, uint256 max) public onlyOwner {
        require(max > min, "bad num");

        _MIN_PENALTY_RATIO_ = min;
        _MAX_PENALTY_RATIO_ = max;
    }

    function setMintLimitRatio(uint256 min, uint256 max) public onlyOwner {
        require(max < 10**18, "bad max");
        require( (max - min)/10**16 > 0, "bad max - min");

        _MIN_MINT_RATIO_ = min;
        _MAX_MINT_RATIO_ = max;
    }

    function getRatioValue(uint256 input) public view returns (uint256) {

        // y = 15% (x < 0.1)
        // y = 5% (x > 0.5)
        // y = 0.175 - 0.25 * x

        if (input <= _MIN_MINT_RATIO_) {
            return _MAX_PENALTY_RATIO_;
        } else if (input >= _MAX_MINT_RATIO_) {
            return _MIN_PENALTY_RATIO_;
        } else {
            uint256 step = (_MAX_PENALTY_RATIO_ - _MIN_PENALTY_RATIO_) * 10 / ((_MAX_MINT_RATIO_ - _MIN_MINT_RATIO_) / 1e16);
            return _MAX_PENALTY_RATIO_ + step - DecimalMath.mulFloor(input, step*10);
        }
    }

    function getSuperior(address account) public view returns (address superior) {
        return userInfo[account].superior;
    }

    // ============ Internal Functions ============

    function _updateAlpha() internal {
        (uint256 newAlpha, uint256 curDistribution) = getLatestAlpha();
        uint256 newTotalDistribution = curDistribution.add(_totalBlockDistribution);
        require(newAlpha <= uint112(-1) && newTotalDistribution <= uint112(-1), "OVERFLOW");
        alpha = uint112(newAlpha);
        _totalBlockDistribution = uint112(newTotalDistribution);
        _lastRewardBlock = uint32(block.number);
        
        if( curDistribution > 0) {
            IMagicBallToken(_mbtToken).mint(address(this), curDistribution);
        
            _totalBlockReward = _totalBlockReward.add(curDistribution);
            emit PreDeposit(curDistribution);
        }
        
    }

    function _mint(UserInfo storage to, uint256 stakingPower) internal {
        require(stakingPower <= uint128(-1), "OVERFLOW");
        UserInfo storage superior = userInfo[to.superior];
        uint256 superiorIncreSP = DecimalMath.mulFloor(stakingPower, _superiorRatio);
        uint256 superiorIncreCredit = DecimalMath.mulFloor(superiorIncreSP, alpha);

        to.stakingPower = uint128(uint256(to.stakingPower).add(stakingPower));
        to.superiorSP = uint128(uint256(to.superiorSP).add(superiorIncreSP));

        superior.stakingPower = uint128(uint256(superior.stakingPower).add(superiorIncreSP));
        superior.credit = uint128(uint256(superior.credit).add(superiorIncreCredit));

        _totalStakingPower = _totalStakingPower.add(stakingPower).add(superiorIncreSP);
    }

    function _redeem(UserInfo storage from, uint256 stakingPower) internal {
        from.stakingPower = uint128(uint256(from.stakingPower).sub(stakingPower));

        uint256 userCreditSP = DecimalMath.divFloor(from.credit, alpha);
        if(from.stakingPower > userCreditSP) {
            from.stakingPower = uint128(uint256(from.stakingPower).sub(userCreditSP));
        } else {
            userCreditSP = from.stakingPower;
            from.stakingPower = 0;
        }
        from.creditDebt = from.creditDebt.add(from.credit);
        from.credit = 0;

        // superior decrease sp = min(stakingPower*0.1, from.superiorSP)
        uint256 superiorDecreSP = DecimalMath.mulFloor(stakingPower, _superiorRatio);
        superiorDecreSP = from.superiorSP <= superiorDecreSP ? from.superiorSP : superiorDecreSP;
        from.superiorSP = uint128(uint256(from.superiorSP).sub(superiorDecreSP));
        uint256 superiorDecreCredit = DecimalMath.mulFloor(superiorDecreSP, alpha);

        UserInfo storage superior = userInfo[from.superior];
        if(superiorDecreCredit > superior.creditDebt) {
            uint256 dec = DecimalMath.divFloor(superior.creditDebt, alpha);
            superiorDecreSP = dec >= superiorDecreSP ? 0 : superiorDecreSP.sub(dec);
            superiorDecreCredit = superiorDecreCredit.sub(superior.creditDebt);
            superior.creditDebt = 0;
        } else {
            superior.creditDebt = superior.creditDebt.sub(superiorDecreCredit);
            superiorDecreCredit = 0;
            superiorDecreSP = 0;
        }
        uint256 creditSP = DecimalMath.divFloor(superior.credit, alpha);

        if (superiorDecreSP >= creditSP) {
            superior.credit = 0;
            superior.stakingPower = uint128(uint256(superior.stakingPower).sub(creditSP));
        } else {
            superior.credit = uint128(
                uint256(superior.credit).sub(superiorDecreCredit)
            );
            superior.stakingPower = uint128(uint256(superior.stakingPower).sub(superiorDecreSP));
        }

        _totalStakingPower = _totalStakingPower.sub(stakingPower).sub(superiorDecreSP).sub(userCreditSP);
    }

    function _transfer(
        address from,
        address to,
        uint256 vMbtAmount
    ) internal canTransfer balanceEnough(from, vMbtAmount) {
        require(from != address(0), "transfer from the zero address");
        require(to != address(0), "transfer to the zero address");
        require(from != to, "transfer from same with to");

        uint256 stakingPower = DecimalMath.divFloor(vMbtAmount * _mbtRatio, alpha);

        UserInfo storage fromUser = userInfo[from];
        UserInfo storage toUser = userInfo[to];

        _redeem(fromUser, stakingPower);
        _mint(toUser, stakingPower);

        emit Transfer(from, to, vMbtAmount);
    }

     function getCirculationSupply() public view returns (uint256 supply) {
        supply = IERC20(_mbtToken).totalSupply();
    }
}