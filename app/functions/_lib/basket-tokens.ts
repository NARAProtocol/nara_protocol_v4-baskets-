/** Static basket token lists for the pairs API (mirrors src/shared/baskets.ts). */

export type BasketTokenRef = {
  symbol: string;
  address: string | null;
};

// Must mirror src/shared/baskets.ts basket assets plus auxiliary route-via tokens.
// NARA resolves from VITE_NARA_TOKEN when GeckoTerminal can list it.
export const BASKET_TOKENS: Record<string, BasketTokenRef[]> = {
  // CORE
  base: [
    { symbol: "NARA",  address: null },
    { symbol: "cbBTC", address: "0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf" },
    { symbol: "WETH",  address: "0x4200000000000000000000000000000000000006" },
    { symbol: "AERO",  address: "0x940181a94A35A4569E4529A3CDfB74e38FD98631" },
    { symbol: "cbETH", address: "0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22" },
  ],
  // AI
  ai: [
    { symbol: "NARA",    address: null },
    { symbol: "VIRTUAL", address: "0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b" },
    { symbol: "VVV",     address: "0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf" },
    { symbol: "AIXBT",   address: "0x4F9Fd6Be4a90f2620860d680c0d4d5Fb53d1A825" },
    { symbol: "WETH",    address: "0x4200000000000000000000000000000000000006" },
  ],
  // CULTURE
  meme: [
    { symbol: "NARA",  address: null },
    { symbol: "BRETT", address: "0x532f27101965dd16442E59d40670FaF5eBB142E4" },
    { symbol: "DEGEN", address: "0x4ed4E862860beD51a9570b96d89aF5E1B0Efefed" },
    { symbol: "TOSHI", address: "0xAC1Bd2486aAf3B5C0fc3Fd868558b082a531B2B4" },
    { symbol: "WETH",  address: "0x4200000000000000000000000000000000000006" },
  ],
  // FINANCE
  defi: [
    { symbol: "NARA", address: null },
    { symbol: "AERO", address: "0x940181a94A35A4569E4529A3CDfB74e38FD98631" },
    { symbol: "MORPHO", address: "0xBAa5CC21fd487B8Fcc2F632f3F4E8D37262a0842" },
    { symbol: "WETH", address: "0x4200000000000000000000000000000000000006" },
  ],
};

export const ALL_BASKET_KEYS = Object.keys(BASKET_TOKENS);
