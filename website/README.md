# LineCrew Pro marketing website

This folder contains the public marketing website for `linecrewpro.com`. It is intentionally separated from the contractor application.

## Planned routing

- `linecrewpro.com` and `www.linecrewpro.com` → public marketing website
- `app.linecrewpro.com` → contractor application
- future `support.linecrewpro.com` → training/help center

## Current website status

The public site now includes a unified LineCrew Pro design across Home, Features, Pricing, Demo/Contact, Training and Signup Preview pages. It also includes Privacy, Terms, a 404 page, a favicon, responsive styling, company-security messaging and the approved high-resolution powerline hero image.

The high-resolution hero currently lives at repository root as `hero-clean.jpg`; `website/styles.css` references it with `../hero-clean.jpg`. Keep the marketing deployment configured so that asset is available, or move/copy the image into the deployed marketing root before switching hosting layouts.

## Commercial status

The current website uses Request a Demo / Contact Sales calls to action. Stripe subscription checkout is intentionally deferred until Line Logic Systems LLC is formed, an EIN is obtained, a business bank account is open, and Stripe is ready for commercial onboarding. The signup page intentionally keeps paid checkout disabled until then.

## Pricing shown

- Starter: 1–5 crews, $499/month
- Business: 6–10 crews, $749/month
- Pro: 11–20 crews, $1,199/month
- Enterprise: 21–40 crews, $1,799/month
- 41+ crews: custom pricing

## Remaining launch tasks

1. Connect the final `linecrewpro.com` marketing deployment and verify the hero asset path in production.
2. Point `app.linecrewpro.com` to the contractor application.
3. Add production-grade social share artwork once the final public asset path is known.
4. Replace email-based demo contact with a server-backed form if desired.
5. After business banking and Stripe are ready, connect subscription checkout and automatic company onboarding.
6. Have Privacy and Terms reviewed before broad commercial launch.
