import type { ReactNode } from "react";
/**
 * Shared chrome for the auth screens (login + signup): a centered card, the
 * OpenCaptions wordmark, a title/subtitle, the form slot and an optional footer.
 *
 * Theme tokens only. The wordmark reuses the header's intentional monochrome
 * "burned-in subtitle cue" treatment — pure black/white that flips with dark
 * mode, so it stays visible in both themes (this is the one deliberate
 * hardcoded-colour exception already established in App.tsx).
 */
export function AuthLayout({
  title,
  subtitle,
  children,
  footer,
}: {
  title: string;
  subtitle?: string;
  children: ReactNode;
  footer?: ReactNode;
}) {
  return (
    <div className="flex min-h-screen flex-col items-center justify-center bg-background px-4 py-12 text-foreground">
      <div className="w-full max-w-sm">
        <div className="mb-8 flex justify-center">
          <span className="inline-flex items-baseline bg-black px-2 py-0.5 text-base font-bold leading-none tracking-tight text-white dark:bg-white dark:text-black">
            OpenCaptions
            <span aria-hidden="true" className="ml-px">
              .
            </span>
          </span>
        </div>
        <div className="rounded-lg border border-border bg-card p-6 shadow-xs">
          <h1 className="text-xl font-semibold">{title}</h1>
          {subtitle && <p className="mt-1 text-sm text-muted-foreground">{subtitle}</p>}
          <div className="mt-6">{children}</div>
        </div>
        {footer && <p className="mt-4 text-center text-sm text-muted-foreground">{footer}</p>}
      </div>
    </div>
  );
}
