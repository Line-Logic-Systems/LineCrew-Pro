import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.4";
import webpush from "npm:web-push@3.6.7";
import { getPublishableKey, getSecretKey } from "../_shared/api-keys.ts";

const VAPID_PUBLIC_KEY = "BM_YU4CTfcI5UWlr0EPYUSTLUO4sQNa0xcSHBUWQNBEwi9N5pHd6Onf43S8dqpYv5vyoUymqyB-nK-x-_Mu-nhE";
const allowedOrigins = new Set([
  "https://app.linecrewpro.com",
  ...(Deno.env.get("CORS_ALLOWED_ORIGINS") || "").split(",").map((value) => value.trim()).filter(Boolean),
]);
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function corsHeaders(request: Request) {
  const origin = request.headers.get("Origin") || "";
  return {
    "Access-Control-Allow-Origin": allowedOrigins.has(origin) ? origin : "https://app.linecrewpro.com",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-push-cron-secret",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

function jsonResponse(request: Request, body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(request), "Content-Type": "application/json" },
  });
}

function cleanText(value: unknown, maximum: number) {
  return String(value || "").trim().slice(0, maximum);
}

function safeRelativeUrl(value: unknown) {
  const url = cleanText(value, 500) || "/";
  return url.startsWith("/") && !url.startsWith("//") ? url : "/";
}

type PushSubscriptionRow = {
  id: string;
  endpoint: string;
  p256dh: string;
  auth: string;
  failure_count: number;
};

type PushError = Error & { statusCode?: number; status?: number };

Deno.serve(async (request) => {
  const requestId = crypto.randomUUID();
  const startedAt = Date.now();
  const origin = request.headers.get("Origin") || "";
  if (origin && !allowedOrigins.has(origin)) {
    return jsonResponse(request, { error: "Origin not allowed.", request_id: requestId }, 403);
  }
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders(request) });

  try {
    if (request.method !== "POST") {
      return jsonResponse(request, { error: "POST required.", request_id: requestId }, 405);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const publishableKey = getPublishableKey();
    const serviceKey = getSecretKey();
    const vapidPrivateKey = Deno.env.get("VAPID_PRIVATE_KEY");
    const vapidSubject = Deno.env.get("VAPID_SUBJECT");
    const pushCronSecret = Deno.env.get("PUSH_CRON_SECRET");
    if (!supabaseUrl || !publishableKey || !serviceKey || !vapidPrivateKey || !vapidSubject) {
      console.error(JSON.stringify({ event: "push_configuration_missing", request_id: requestId }));
      return jsonResponse(request, { error: "Push notification service is unavailable.", request_id: requestId }, 503);
    }
    try {
      webpush.setVapidDetails(vapidSubject, VAPID_PUBLIC_KEY, vapidPrivateKey);
    } catch (_error) {
      console.error(JSON.stringify({ event: "push_configuration_invalid", request_id: requestId }));
      return jsonResponse(request, { error: "Push notification service is unavailable.", request_id: requestId }, 503);
    }

    const body = await request.json().catch(() => ({})) as Record<string, unknown>;
    const mode = cleanText(body.mode, 20).toLowerCase();
    if (mode !== "test" && mode !== "notify") {
      return jsonResponse(request, { error: "A valid push mode is required.", request_id: requestId }, 400);
    }

    const service = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    let subscriptions: PushSubscriptionRow[] = [];
    let payload: Record<string, unknown>;

    if (mode === "test") {
      const authorization = request.headers.get("Authorization");
      if (!authorization) {
        return jsonResponse(request, { error: "Authentication required.", request_id: requestId }, 401);
      }
      const userClient = createClient(supabaseUrl, publishableKey, {
        global: { headers: { Authorization: authorization } },
        auth: { persistSession: false, autoRefreshToken: false },
      });
      const { data: userData, error: userError } = await userClient.auth.getUser();
      if (userError || !userData.user) {
        return jsonResponse(request, { error: "Authentication required.", request_id: requestId }, 401);
      }
      const { data, error } = await service
        .from("push_subscriptions")
        .select("id,endpoint,p256dh,auth,failure_count")
        .eq("user_id", userData.user.id);
      if (error) throw error;
      subscriptions = (data || []) as PushSubscriptionRow[];
      payload = {
        title: "LineCrew Pro",
        body: "Test notification received. Notifications are working on this device.",
        tag: "linecrew-test-notification",
        renotify: false,
        url: "/",
        data: { type: "test" },
      };
    } else {
      const suppliedSecret = request.headers.get("x-push-cron-secret") || "";
      if (!pushCronSecret || suppliedSecret !== pushCronSecret) {
        return jsonResponse(request, { error: "Unauthorized.", request_id: requestId }, 401);
      }
      const requestedUserIds = Array.isArray(body.user_ids)
        ? [...new Set(body.user_ids.map((value) => cleanText(value, 36)).filter((value) => uuidPattern.test(value)))].slice(0, 500)
        : [];
      if (!requestedUserIds.length) {
        return jsonResponse(request, { error: "At least one valid user is required.", request_id: requestId }, 400);
      }
      const { data, error } = await service
        .from("push_subscriptions")
        .select("id,endpoint,p256dh,auth,failure_count")
        .in("user_id", requestedUserIds);
      if (error) throw error;
      subscriptions = (data || []) as PushSubscriptionRow[];
      payload = {
        title: cleanText(body.title, 120) || "LineCrew Pro",
        body: cleanText(body.body, 240) || "You have a new LineCrew Pro notification.",
        tag: cleanText(body.tag, 120) || undefined,
        renotify: false,
        url: safeRelativeUrl(body.url),
      };
    }

    const results = { sent: 0, failed: 0, removed: 0 };
    await Promise.all(subscriptions.map(async (subscription) => {
      let deliveryError: PushError | null = null;
      try {
        await webpush.sendNotification({
          endpoint: subscription.endpoint,
          keys: { p256dh: subscription.p256dh, auth: subscription.auth },
        }, JSON.stringify(payload), {
          vapidDetails: {
            subject: vapidSubject,
            publicKey: VAPID_PUBLIC_KEY,
            privateKey: vapidPrivateKey,
          },
          TTL: 300,
        });
      } catch (error) {
        deliveryError = error as PushError;
      }

      if (!deliveryError) {
        const { error } = await service.from("push_subscriptions").update({
          last_success_at: new Date().toISOString(),
          failure_count: 0,
        }).eq("id", subscription.id);
        if (error) throw error;
        results.sent += 1;
        return;
      }

      results.failed += 1;
      const status = Number(deliveryError.statusCode || deliveryError.status || 0);
      const nextFailureCount = Number(subscription.failure_count || 0) + 1;
      if (status === 404 || status === 410 || nextFailureCount > 10) {
        const { error: deleteError } = await service.from("push_subscriptions").delete().eq("id", subscription.id);
        if (deleteError) throw deleteError;
        results.removed += 1;
      } else {
        const { error: updateError } = await service.from("push_subscriptions")
          .update({ failure_count: nextFailureCount }).eq("id", subscription.id);
        if (updateError) throw updateError;
      }
      console.error(JSON.stringify({
        event: "push_delivery_failed",
        request_id: requestId,
        status,
        removed: status === 404 || status === 410 || nextFailureCount > 10,
      }));
    }));

    console.log(JSON.stringify({
      event: "push_delivery_completed",
      request_id: requestId,
      mode,
      subscriptions: subscriptions.length,
      sent: results.sent,
      failed: results.failed,
      removed: results.removed,
      duration_ms: Date.now() - startedAt,
    }));
    return jsonResponse(request, { ok: results.failed === 0, ...results, request_id: requestId });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unable to send push notification.";
    console.error(JSON.stringify({
      event: "push_delivery_failed",
      request_id: requestId,
      message: message.slice(0, 300),
      duration_ms: Date.now() - startedAt,
    }));
    return jsonResponse(request, {
      error: "Unable to send push notification.",
      request_id: requestId,
    }, 500);
  }
});
