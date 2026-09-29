// lib/curatedModels.ts
// The curated OpenRouter model pack — the ONLY OpenRouter models offered in the WEB pickers.
// Replaces the ~340-model live-catalog firehose (openrouter.ai/api/v1/models) with a hand-picked,
// verified set so the dropdowns stay usable. Every slug below was verified against the live
// OpenRouter catalog. This file is the single source of truth; edit here to change the pack.
//
// THINKING / REASONING
// --------------------
// A "thinking" entry shares its base slug with a plain sibling and differs ONLY by OpenRouter's
// `reasoning` parameter (e.g. "Claude Opus 4.6 Thinking" and "Claude Opus 4.6" both send
// `anthropic/claude-opus-4.6`). So selection is keyed, not slug-based: reasoning variants use a
// `${slug}#thinking` key, plain models use the bare slug as the key.
//
// PER-SURFACE POLICY
//   - Chat  : honours a model's reasoning (thinking on) — resolveModelRequest keeps `reasoning`.
//   - Repeater : its own independent selector, thinking OFF — it stores bare slugs, so the
//     resolver returns no `reasoning`. Keep it that way (fast tool-loop; Kimi/DeepSeek workhorses).

export type ReasoningEffort = 'high' | 'xhigh' | 'medium' | 'low';

export interface CuratedModel {
    /** Unique selection key. Reasoning variants: `${id}#thinking`; plain models: the bare slug. */
    key: string;
    /** OpenRouter slug sent as the request `model`. */
    id: string;
    /** Display label shown in the picker. */
    name: string;
    /** When set, the chat surface sends `reasoning: { effort }` (thinking on). */
    reasoning?: ReasoningEffort;
}

// Order roughly follows the operator's own priority list.
export const CURATED_MODELS: CuratedModel[] = [
    { key: "Atria-Dawn-Preview", name: "Atria Dawn (Preview)", id: "Atria-Dawn-Preview" },
];

/** All selection keys, in pack order (for building dropdowns). */
export const CURATED_MODEL_KEYS: string[] = CURATED_MODELS.map((m) => m.key);

/** Bare slugs only, de-duplicated — for the Repeater picker (thinking-free). */
export const CURATED_MODEL_IDS: string[] = Array.from(new Set(CURATED_MODELS.map((m) => m.id)));

/** Chat default: a fast, capable model that exists in the pack. */
export const DEFAULT_CHAT_MODEL_KEY = "Atria-Dawn-Preview";
/** Repeater default: a non-refusing workhorse (thinking-free) the operator reports works well. */
export const DEFAULT_REPEATER_MODEL_ID = "Atria-Dawn-Preview";

const byKey = new Map(CURATED_MODELS.map((m) => [m.key, m]));

/** Display label for a stored key/slug (falls back to the raw value for unknown/other-provider ids). */
export const curatedModelName = (keyOrId: string): string =>
    byKey.get(keyOrId)?.name ?? CURATED_MODELS.find((m) => m.id === keyOrId)?.name ?? keyOrId;

/**
 * Resolve a stored selection (key or bare slug) into the request pieces.
 *   - Known reasoning key + allowReasoning → { model: slug, reasoning: { effort } }
 *   - Otherwise                            → { model: slug }
 * Unknown values (e.g. a non-OpenRouter provider's model id) pass straight through.
 */
export const resolveModelRequest = (
    keyOrId: string,
    opts?: { allowReasoning?: boolean },
): { model: string; reasoning?: { effort: ReasoningEffort } } => {
    const m = byKey.get(keyOrId);
    if (!m) return { model: keyOrId };
    const allow = opts?.allowReasoning !== false;
    return allow && m.reasoning ? { model: m.id, reasoning: { effort: m.reasoning } } : { model: m.id };
};
