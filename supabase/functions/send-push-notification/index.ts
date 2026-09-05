import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.4";
import webpush from "npm:web-push@3.6.7";
import { getPublishableKey, getSecretKey } from "../_shared/api-keys.ts";

const VAPID_PUBLIC_KEY = "BGJsa3SAbOkoEWevDwhvoGG1fT4v2CkeQjX7QD-Tblo4Hh2I7YZYfQWx9CWiF8xPHRWGWYkjVAO6774-hHFKx30";
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

type PushOutboxRow = {
  id: string;
  recipient_id: string;
  title: string;
  body: string;
  url: string;
  tag: string;
  attempt_count: number;
};

async function deliverPush(
  service: ReturnType<typeof createClient>,
  subscriptions: PushSubscriptionRow[],
  payload: Record<string, unknown>,
  vapidSubject: string,
  vapidPrivateKey: string,
  requestId: string,
) {
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
  return results;
}

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
      if (body.dispatch_queued === true) {
        const { error: reminderError } = await service.rpc("linecrew_enqueue_due_push_reminders");
        if (reminderError) throw reminderError;

        const staleBefore = new Date(Date.now() - 10 * 60 * 1000).toISOString();
        const { error: staleError } = await service.from("push_notification_outbox").update({
          status: "pending",
          locked_at: null,
          available_at: new Date().toISOString(),
          updated_at: new Date().toISOString(),
        }).eq("status", "processing").lt("locked_at", staleBefore);
        if (staleError) throw staleError;

        const { data: queued, error: queuedError } = await service
          .from("push_notification_outbox")
          .select("id,recipient_id,title,body,url,tag,attempt_count")
          .eq("status", "pending")
          .lte("available_at", new Date().toISOString())
          .order("created_at", { ascending: true })
          .limit(50);
        if (queuedError) throw queuedError;

        const totals = { events: 0, sent: 0, failed: 0, removed: 0 };
        for (const queuedEvent of (queued || []) as PushOutboxRow[]) {
          const claimTime = new Date().toISOString();
          const { data: claimed, error: claimError } = await service
            .from("push_notification_outbox")
            .update({
              status: "processing",
              locked_at: claimTime,
              attempt_count: Number(queuedEvent.attempt_count || 0) + 1,
              updated_at: claimTime,
            })
            .eq("id", queuedEvent.id)
            .eq("status", "pending")
            .select("id")
            .maybeSingle();
          if (claimError) throw claimError;
          if (!claimed) continue;

          try {
            const { data: recipientSubscriptions, error: subscriptionError } = await service
              .from("push_subscriptions")
              .select("id,endpoint,p256dh,auth,failure_count")
              .eq("user_id", queuedEvent.recipient_id);
            if (subscriptionError) throw subscriptionError;
            const eventResult = await deliverPush(
              service,
              (recipientSubscriptions || []) as PushSubscriptionRow[],
              {
                title: cleanText(queuedEvent.title, 120) || "LineCrew Pro",
                body: cleanText(queuedEvent.body, 240) || "You have a new LineCrew Pro notification.",
                tag: cleanText(queuedEvent.tag, 120) || undefined,
                renotify: false,
                url: safeRelativeUrl(queuedEvent.url),
              },
              vapidSubject,
              vapidPrivateKey,
              requestId,
            );
            const completedAt = new Date().toISOString();
            const { error: completeError } = await service.from("push_notification_outbox").update({
              status: "sent",
              sent_at: completedAt,
              locked_at: null,
              last_error: null,
              updated_at: completedAt,
            }).eq("id", queuedEvent.id).eq("status", "processing");
            if (completeError) throw completeError;
            totals.events += 1;
            totals.sent += eventResult.sent;
            totals.failed += eventResult.failed;
            totals.removed += eventResult.removed;
          } catch (eventError) {
            const attempts = Number(queuedEvent.attempt_count || 0) + 1;
            const retryAt = new Date(Date.now() + Math.min(60, 2 ** attempts) * 60 * 1000).toISOString();
            const failedAt = new Date().toISOString();
            const { error: releaseError } = await service.from("push_notification_outbox").update({
              status: attempts >= 6 ? "failed" : "pending",
              available_at: retryAt,
              locked_at: null,
              last_error: cleanText(eventError instanceof Error ? eventError.message : "Push dispatch failed.", 300),
              updated_at: failedAt,
            }).eq("id", queuedEvent.id).eq("status", "processing");
            if (releaseError) throw releaseError;
            totals.failed += 1;
          }
        }

        console.log(JSON.stringify({
          event: "push_queue_dispatch_completed",
          request_id: requestId,
          ...totals,
          duration_ms: Date.now() - startedAt,
        }));
        return jsonResponse(request, { ok: totals.failed === 0, ...totals, request_id: requestId });
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

    const results = await deliverPush(
      service,
      subscriptions,
      payload,
      vapidSubject,
      vapidPrivateKey,
      requestId,
    );

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
