// Javascript Ethereum API Library
const ethers = require("ethers");

exports.getEncodedActionKyberTradeParams = (
  user,
  src,
  dest,
  srcAmount,
  minConversionRate
) => {
  const abiCoder = ethers.utils.defaultAbiCoder;
  const encodedActionParams = abiCoder.encode(
    ["address", "address", "address", "uint256", "uint256"],
    [user, src, dest, srcAmount, minConversionRate]
  );
  return encodedActionParams;
};

exports.getActionKyberTradePayloadWithSelector = (
  // action params
  _user,
  _src,
  _srcAmt,
  _dest,
  _minConversionRate
) => {
  const actionKyberTradeABI = [
    {
      name: "action",
      type: "function",
      inputs: [
        { type: "address", name: "_user" },
        { type: "address", name: "_src" },
        { type: "uint256", name: "_srcAmt" },
        { type: "address", name: "_dest" },
        { type: "uint256", name: "_minConversionRate" }
      ]
    }
  ];
  const interface = new ethers.utils.Interface(actionKyberTradeABI);

  const actionPayloadWithSelector = interface.functions.action.encode([
    _user,
    _src,
    _srcAmt,
    _dest,
    _minConversionRate
  ]);

  return actionPayloadWithSelector;
};
