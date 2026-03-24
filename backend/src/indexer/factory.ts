import { ethers } from "ethers";
import { getLogger, Logger } from "../utils";

const FACTORY_ABI = [
  "function getOrderFlowAddress(address owner) view returns (address)",
];

/**
 * Verifies that an emitting contract address is a legitimate OrderFlow
 * instance deployed by our factory.
 *
 * Calls factory.getOrderFlowAddress(owner) once per unique owner,
 * then caches the result permanently.
 */
export class FactoryVerifier {
  private factory: ethers.Contract;
  private cache: Map<string, string> = new Map();
  private log: Logger;

  constructor(factoryAddress: string, provider: ethers.Provider) {
    this.factory = new ethers.Contract(factoryAddress, FACTORY_ABI, provider);
    this.log = getLogger("FactoryVerifier", { factory: factoryAddress });
  }

  /**
   * Check if `emitter` is the legitimate OrderFlow contract for `owner`.
   *
   * @param owner  The sender/owner from the OrderPlacement event (indexed topic).
   * @param emitter The contract address that emitted the event (rawLog.address).
   * @returns true if the factory confirms this address.
   */
  async isLegitimate(owner: string, emitter: string): Promise<boolean> {
    const ownerLower = owner.toLowerCase();
    const emitterLower = emitter.toLowerCase();

    const cached = this.cache.get(ownerLower);
    if (cached !== undefined) {
      return cached === emitterLower;
    }

    try {
      const expected: string = await this.factory.getOrderFlowAddress(owner);
      const expectedLower = expected.toLowerCase();
      this.cache.set(ownerLower, expectedLower);

      if (expectedLower !== emitterLower) {
        this.log.debug(
          `Rejected OrderPlacement from ${emitter} for owner ${owner} (expected ${expected})`,
        );
        return false;
      }

      this.log.debug(`Verified OrderFlow ${emitter} for owner ${owner}`);
      return true;
    } catch (err) {
      this.cache.set(ownerLower, "");
      this.log.debug(
        `Rejected OrderPlacement from ${emitter} for owner ${owner} (factory call failed)`,
      );
      return false;
    }
  }
}
