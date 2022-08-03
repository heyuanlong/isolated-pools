const {
  makeComptroller,
  makeCToken,
  setMarketSupplyCap
} = require('../Utils/Compound');

describe('CToken', function () {
  let root, accounts;
  let cToken, oldComptroller, newComptroller;
  beforeEach(async () => {
    [root, ...accounts] = saddle.accounts;
    cToken = await makeCToken();
    oldComptroller = cToken.comptroller;
    newComptroller = await makeComptroller();
    await setMarketSupplyCap(cToken.comptroller, [cToken._address], [100000000000]);
    expect(newComptroller._address).not.toEqual(oldComptroller._address);
  });

  describe('_setComptroller', () => {
    it("should fail if called by non-admin", async () => {
      await expect(send(cToken, '_setComptroller', [newComptroller._address], { from: accounts[0] }))
        .rejects.toRevertWithCustomError('SetComptrollerOwnerCheck');
      expect(await call(cToken, 'comptroller')).toEqual(oldComptroller._address);
    });

    it("reverts if passed a contract that doesn't implement isComptroller", async () => {
      await expect(send(cToken, '_setComptroller', [cToken.underlying._address]))
        .rejects.toRevert("revert");
      expect(await call(cToken, 'comptroller')).toEqual(oldComptroller._address);
    });

    it("reverts if passed a contract that implements isComptroller as false", async () => {
      // extremely unlikely to occur, of course, but let's be exhaustive
      const badComptroller = await makeComptroller({ kind: 'false-marker' });
      await expect(send(cToken, '_setComptroller', [badComptroller._address]))
        .rejects.toRevert("revert marker method returned false");
      expect(await call(cToken, 'comptroller')).toEqual(oldComptroller._address);
    });

    it("updates comptroller and emits log on success", async () => {
      const result = await send(cToken, '_setComptroller', [newComptroller._address]);
      expect(result).toSucceed();
      expect(result).toHaveLog('NewComptroller', {
        oldComptroller: oldComptroller._address,
        newComptroller: newComptroller._address
      });
      expect(await call(cToken, 'comptroller')).toEqual(newComptroller._address);
    });
  });
});
