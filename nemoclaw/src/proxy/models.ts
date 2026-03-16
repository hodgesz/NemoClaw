// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

export interface CuratedModel {
  id: string;
  prefixedId: string;
  label: string;
  extraBody: Record<string, unknown>;
  aliases: string[];
  contextWindow: number;
  maxOutput: number;
}

export const DEFAULT_TEMPERATURE = 1.0;
export const DEFAULT_TOP_P = 0.95;

export const PROXY_HEADERS: Record<string, string> = {
  "NVCF-POLL-SECONDS": "1800",
  "X-BILLING-INVOKE-ORIGIN": "openshell",
};

const MODEL_PREFIX = "private/openshell";

function prefixed(id: string): string {
  return `${MODEL_PREFIX}/${id}`;
}

const CURATED_MODELS_LIST: CuratedModel[] = [
  {
    id: "moonshotai/kimi-k2.5",
    prefixedId: prefixed("moonshotai/kimi-k2.5"),
    label: "Kimi K2.5",
    extraBody: { chat_template_kwargs: { thinking: true } },
    aliases: ["curated-nvidia-endpoints/moonshotai/kimi-k2.5"],
    contextWindow: 131072,
    maxOutput: 8192,
  },
  {
    id: "minimaxai/minimax-m2.5",
    prefixedId: prefixed("minimaxai/minimax-m2.5"),
    label: "MiniMax M2.5",
    extraBody: {},
    aliases: ["curated-nvidia-endpoints/minimaxai/minimax-m2.5"],
    contextWindow: 131072,
    maxOutput: 8192,
  },
  {
    id: "z-ai/glm5",
    prefixedId: prefixed("z-ai/glm5"),
    label: "GLM 5",
    extraBody: { chat_template_kwargs: { enable_thinking: true } },
    aliases: ["curated-nvidia-endpoints/z-ai/glm5"],
    contextWindow: 131072,
    maxOutput: 8192,
  },
  {
    id: "nvidia/nemotron-3-super-120b-a12b",
    prefixedId: prefixed("nvidia/nemotron-3-super-120b-a12b"),
    label: "Nemotron 3 Super",
    extraBody: {
      chat_template_kwargs: {
        enable_thinking: true,
        force_nonempty_content: true,
      },
    },
    aliases: ["curated-nvidia-endpoints/nvidia/nemotron-3-super-120b-a12b"],
    contextWindow: 131072,
    maxOutput: 8192,
  },
  {
    id: "openai/gpt-oss-120b",
    prefixedId: prefixed("openai/gpt-oss-120b"),
    label: "GPT-OSS 120B",
    extraBody: { reasoning_effort: "high" },
    aliases: ["curated-nvidia-endpoints/openai/gpt-oss-120b"],
    contextWindow: 131072,
    maxOutput: 8192,
  },
];

export const CURATED_MODELS: ReadonlyMap<string, CuratedModel> = (() => {
  const map = new Map<string, CuratedModel>();
  for (const m of CURATED_MODELS_LIST) {
    map.set(m.id, m);
    for (const alias of m.aliases) {
      map.set(alias, m);
    }
  }
  return map;
})();

export function getAllCuratedModels(): readonly CuratedModel[] {
  return CURATED_MODELS_LIST;
}
