import React from "react";
import ReactDOM from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { RainbowKitProvider, connectorsForWallets } from "@rainbow-me/rainbowkit";
import {
  base as baseWallet,
  metaMaskWallet,
  walletConnectWallet,
  injectedWallet,
} from "@rainbow-me/rainbowkit/wallets";
import { WagmiProvider, createConfig } from "wagmi";
import { base } from "wagmi/chains";
import { http } from "viem";

import App from "./app";

import "@rainbow-me/rainbowkit/styles.css";
import "./styles.css";

const projectId =
  import.meta.env.VITE_RAINBOW_PROJECT_ID ||
  import.meta.env.VITE_WALLETCONNECT_PROJECT_ID ||
  "00000000000000000000000000000000";

// Local-fork dummy run: keep chainId 8453 (so all addresses/ABIs match Base) but
// route RPC to the anvil fork on localhost:8545. Toggled by VITE_USE_FORK=true.
const useFork = import.meta.env.VITE_USE_FORK === "true";
const forkChain = {
  ...base,
  rpcUrls: {
    default: { http: ["http://localhost:8545"] },
    public: { http: ["http://localhost:8545"] },
  },
};

// Onboarding-first connector order: Base Account (passkey smart wallet, no seed
// phrase, supports gasless/EIP-5792) is offered first for brand-new users;
// existing-wallet users still get MetaMask / WalletConnect / injected.
// `base` is RainbowKit's current canonical connector for Coinbase's smart wallet
// (rebranded "Base Account"); the legacy `coinbaseWallet` export is now marked
// deprecated in favor of it as of @rainbow-me/rainbowkit 2.2.11.
const connectors = connectorsForWallets(
  [
    { groupName: "Easiest", wallets: [baseWallet] },
    { groupName: "Other wallets", wallets: [metaMaskWallet, walletConnectWallet, injectedWallet] },
  ],
  { appName: "NARA Baskets", projectId },
);

const config = createConfig({
  connectors,
  chains: [useFork ? forkChain : base],
  transports: {
    [base.id]: http(useFork ? "http://localhost:8545" : undefined),
  },
});

if (useFork) {
  // eslint-disable-next-line no-console
  console.info("[NARA Baskets] FORK MODE — RPC: localhost:8545, NARA = LINK stand-in");
}

const queryClient = new QueryClient();

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider>
          <App />
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  </React.StrictMode>,
);
