import * as DropdownMenu from "@radix-ui/react-dropdown-menu";
import { Check, LogOut, User, UserCog } from "lucide-react";
import { useNavigate } from "react-router-dom";
import { getLanguage, LANGUAGES, type LanguageCode, setLanguage, useT } from "@/lib/i18n";
import { iconButtonClass } from "@/lib/ui";
import { useAuthStore } from "@/store/authStore";
/**
 * Header account control: a single silhouette icon button that opens a small
 * menu. The menu shows who you're signed in as and offers sign-out.
 *
 * Why a menu and not the old email-text + logout-icon pair: it collapses the
 * identity affordance to one button and gives us a place to hang future
 * account actions (settings, profile, …) by dropping another
 * <DropdownMenu.Item> into the list below: no header surgery required.
 *
 * Built on @radix-ui/react-dropdown-menu, so the accessibility comes for free:
 * the trigger gets aria-haspopup/aria-expanded, the surface is role="menu" with
 * role="menuitem" children, focus moves into the menu on open and returns to the
 * trigger on close, and Escape (or an outside click) dismisses it. The trigger's
 * aria-label names the signed-in account so a screen reader announces it.
 *
 * Zustand identity rule: only primitives / the stable action ref are selected
 * (s.user?.email, s.logout): never a store object/array.
 */
export function UserMenu() {
  const t = useT();
  const navigate = useNavigate();
  const email = useAuthStore((s) => s.user?.email);
  const logout = useAuthStore((s) => s.logout);

  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild>
        <button
          type="button"
          // The non-accent icon-button hierarchy (transparent, outlined,
          // high-contrast foreground, accent-on-hover), identical to the Info
          // and theme-toggle buttons. Never a filled accent: that is reserved
          // for the primary action.
          className={iconButtonClass}
          aria-label={email ? t("Account: {email}", { email }) : t("Account")}
          title={t("Account")}
          data-testid="user-menu"
        >
          <User className="h-4 w-4" aria-hidden />
        </button>
      </DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content
          align="end"
          sideOffset={6}
          data-testid="user-menu-content"
          className="z-50 min-w-48 rounded-md border border-border bg-card p-1 text-card-foreground shadow-lg"
        >
          {email && (
            <>
              <DropdownMenu.Label className="px-2 py-1.5">
                <span className="block text-[11px] text-muted-foreground">{t("Signed in as")}</span>
                <span className="block truncate text-sm font-medium" data-testid="user-menu-email">
                  {email}
                </span>
              </DropdownMenu.Label>
              <DropdownMenu.Separator className="my-1 h-px bg-border" />
            </>
          )}
          <DropdownMenu.Item
            onSelect={() => navigate("/account")}
            data-testid="account-link"
            className="flex cursor-pointer select-none items-center gap-2 rounded-sm px-2 py-1.5 text-sm outline-hidden transition-colors data-highlighted:bg-accent data-highlighted:text-accent-foreground"
          >
            <UserCog className="h-4 w-4" aria-hidden />
            {t("Account")}
          </DropdownMenu.Item>
          <DropdownMenu.Separator className="my-1 h-px bg-border" />
          <DropdownMenu.Label className="px-2 pt-1 text-[11px] text-muted-foreground">
            {t("Language")}
          </DropdownMenu.Label>
          <DropdownMenu.RadioGroup
            value={getLanguage()}
            onValueChange={(code) => setLanguage(code as LanguageCode)}
          >
            {LANGUAGES.map((l) => (
              <DropdownMenu.RadioItem
                key={l.code}
                value={l.code}
                data-testid={`language-${l.code}`}
                className="flex cursor-pointer select-none items-center gap-2 rounded-sm py-1.5 pl-8 pr-2 text-sm outline-hidden transition-colors data-highlighted:bg-accent data-highlighted:text-accent-foreground"
              >
                <DropdownMenu.ItemIndicator className="absolute left-2">
                  <Check className="h-4 w-4" aria-hidden />
                </DropdownMenu.ItemIndicator>
                {l.name}
              </DropdownMenu.RadioItem>
            ))}
          </DropdownMenu.RadioGroup>
          <DropdownMenu.Separator className="my-1 h-px bg-border" />
          <DropdownMenu.Item
            onSelect={() => {
              void logout();
            }}
            data-testid="logout"
            className="flex cursor-pointer select-none items-center gap-2 rounded-sm px-2 py-1.5 text-sm outline-hidden transition-colors data-highlighted:bg-accent data-highlighted:text-accent-foreground"
          >
            <LogOut className="h-4 w-4" aria-hidden />
            {t("Sign out")}
          </DropdownMenu.Item>
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}
