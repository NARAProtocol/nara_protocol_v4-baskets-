/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_RAINBOW_PROJECT_ID?: string;
  readonly VITE_WALLETCONNECT_PROJECT_ID?: string;
  readonly VITE_BASKET_MANAGER_BASE?: string;
  readonly VITE_BASKET_MANAGER_AI?: string;
  readonly VITE_BASKET_MANAGER_MEME?: string;
  readonly VITE_BASKET_MANAGER_DEFI?: string;
  readonly VITE_BASKET_ADAPTER?: string;
  readonly VITE_BASKET_ADAPTER_AERO?: string;
  readonly VITE_BASKET_ADAPTER_SLIPSTREAM?: string;
  readonly VITE_BASKET_ADAPTER_PANCAKE?: string;
  readonly VITE_BASKET_ADAPTER_V4?: string;
  readonly VITE_NARA_FEE_COLLECTOR?: string;
  readonly VITE_NARA_TOKEN?: string;
  readonly VITE_NARA_V4_HOOK?: string;
  readonly VITE_NARA_V4_POOL_FEE?: string;
  readonly VITE_NARA_V4_TICK_SPACING?: string;
  readonly VITE_UNISWAP_V4_QUOTER?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
