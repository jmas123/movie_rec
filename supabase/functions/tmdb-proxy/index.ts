// TMDB proxy — roadmap Phase 28 step 6, closing open question 11.
//
// The app ships the TMDB token in its bundle, which is fine for an unsubmitted
// build and extractable the moment it reaches TestFlight. Now that a backend
// exists, the credential can live here instead and the client can carry none.
//
// Deliberately a *narrow* proxy: an allow-list of paths, not a general
// forwarder. An open proxy attached to someone's API key is a gift to whoever
// finds it.

import { serve } from "https://deno.land/std@0.208.0/http/server.ts";

const TMDB = "https://api.themoviedb.org/3";
const TOKEN = Deno.env.get("TMDB_READ_TOKEN");

// Only what the app actually calls.
const ALLOWED = [
  /^search\/multi$/,
  /^search\/keyword$/,
  /^discover\/(movie|tv)$/,
  /^(movie|tv)\/\d+$/,
  /^genre\/(movie|tv)\/list$/,
  /^find\/tt\d+$/,
  // A cast member's filmography, for the screen that asks which of an actor's
  // titles the people you follow liked. Cast-only: `combined_credits` carries a
  // `crew` array too, and the app reads the `cast` half of it.
  /^person\/\d+\/combined_credits$/,
];

serve(async (request) => {
  if (!TOKEN) {
    return new Response(JSON.stringify({ message: "Proxy is not configured" }), {
      status: 503,
      headers: { "content-type": "application/json" },
    });
  }

  const url = new URL(request.url);
  // Everything after the function name is the TMDB path.
  const path = url.pathname.replace(/^\/tmdb-proxy\/?/, "");

  if (!ALLOWED.some((pattern) => pattern.test(path))) {
    return new Response(JSON.stringify({ message: "Path not allowed" }), {
      status: 403,
      headers: { "content-type": "application/json" },
    });
  }

  const target = new URL(`${TMDB}/${path}`);
  target.search = url.search;

  const response = await fetch(target, {
    headers: { Authorization: `Bearer ${TOKEN}`, Accept: "application/json" },
  });

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": "application/json",
      // TMDB data is not per-user, so it is safe and cheap to cache at the edge.
      "cache-control": "public, max-age=3600",
    },
  });
});
