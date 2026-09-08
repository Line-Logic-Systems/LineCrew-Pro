export type BetaSalesApplication = {
  id: string;
  submitted_at: string;
  companyName: string;
  contactName: string;
  email: string;
  phone: string;
  crews: number;
  notes: string;
};

export type BetaSalesNotificationResult = {
  sent: boolean;
  providerId: string | null;
  error: string | null;
};

function escapeHtml(value: unknown) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function providerError(body: unknown, status: number) {
  if (body && typeof body === "object") {
    const record = body as Record<string, unknown>;
    const message = typeof record.message === "string"
      ? record.message
      : typeof record.error === "string"
      ? record.error
      : null;
    if (message) return `Resend ${status}: ${message}`.slice(0, 500);
  }
  return `Resend rejected the request with HTTP ${status}.`;
}

export async function sendBetaSalesNotification(
  application: BetaSalesApplication,
  attemptNumber: number,
): Promise<BetaSalesNotificationResult> {
  const resendApiKey = Deno.env.get("RESEND_API_KEY");
  if (!resendApiKey) {
    return { sent: false, providerId: null, error: "RESEND_API_KEY is not configured." };
  }

  const subject = `[Beta Application] ${application.companyName} — ${application.crews} crew${application.crews === 1 ? "" : "s"}`;
  const text = [
    "New LineCrew Pro Beta/Pilot application",
    "",
    `Company: ${application.companyName}`,
    `Contact: ${application.contactName}`,
    `Email: ${application.email}`,
    `Phone: ${application.phone || "Not provided"}`,
    `Active crews: ${application.crews}`,
    `Submitted: ${application.submitted_at}`,
    `Application ID: ${application.id}`,
    "",
    "What they want to test:",
    application.notes || "Not provided",
    "",
    "Review this application in the LineCrew Pro Platform Support Console.",
    "https://app.linecrewpro.com/support.html",
  ].join("\n");

  const html = `<!doctype html><html><body style="margin:0;background:#f4f7f5;font-family:Arial,sans-serif;color:#15231b"><div style="max-width:680px;margin:0 auto;padding:32px 20px"><div style="background:#fff;border:1px solid #dce6df;border-radius:12px;padding:28px"><h1 style="margin:0 0 18px;font-size:22px">New Beta/Pilot application</h1><table style="border-collapse:collapse;width:100%;font-size:14px"><tr><td style="padding:5px 12px 5px 0;color:#526158">Company</td><td><strong>${escapeHtml(application.companyName)}</strong></td></tr><tr><td style="padding:5px 12px 5px 0;color:#526158">Contact</td><td>${escapeHtml(application.contactName)}</td></tr><tr><td style="padding:5px 12px 5px 0;color:#526158">Email</td><td>${escapeHtml(application.email)}</td></tr><tr><td style="padding:5px 12px 5px 0;color:#526158">Phone</td><td>${escapeHtml(application.phone || "Not provided")}</td></tr><tr><td style="padding:5px 12px 5px 0;color:#526158">Active crews</td><td>${application.crews}</td></tr><tr><td style="padding:5px 12px 5px 0;color:#526158">Submitted</td><td>${escapeHtml(application.submitted_at)}</td></tr></table><div style="margin-top:20px;padding:16px;background:#f4f7f5;border-radius:8px;white-space:pre-wrap;line-height:1.45"><strong>What they want to test</strong><br>${escapeHtml(application.notes || "Not provided")}</div><p style="margin:22px 0 0"><a href="https://app.linecrewpro.com/support.html" style="display:inline-block;padding:10px 16px;background:#15231b;color:#fff;text-decoration:none;border-radius:7px">Review application</a></p><p style="font-size:12px;color:#6a746e;margin:18px 0 0">Application ID: ${escapeHtml(application.id)}</p></div></div></body></html>`;

  try {
    const response = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${resendApiKey}`,
        "Content-Type": "application/json",
        "Idempotency-Key": `beta-application-${application.id}-${attemptNumber}`,
      },
      body: JSON.stringify({
        from: "LineCrew Pro <invites@auth.linecrewpro.com>",
        to: ["sales@linecrewpro.com"],
        reply_to: application.email,
        subject,
        text,
        html,
      }),
    });
    const responseBody = await response.json().catch(() => null) as Record<string, unknown> | null;
    if (!response.ok) {
      return { sent: false, providerId: null, error: providerError(responseBody, response.status) };
    }
    const providerId = typeof responseBody?.id === "string" ? responseBody.id : null;
    return providerId
      ? { sent: true, providerId, error: null }
      : { sent: false, providerId: null, error: "Resend accepted the request without returning an email ID." };
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unknown network error";
    return { sent: false, providerId: null, error: `Unable to reach Resend: ${message}`.slice(0, 500) };
  }
}
