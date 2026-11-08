import { useEffect, useState } from "preact/hooks";

export interface AuthUser {
	login: string;
	id: number;
	avatarUrl: string | null;
	twoFactorAuthentication: boolean;
}

export function useAuth() {
	const [user, setUser] = useState<AuthUser | null>(null);
	const [loading, setLoading] = useState(true);

	useEffect(() => {
		let cancelled = false;
		fetch("/api/auth/me")
			.then((response) => (response.ok ? response.json() : null))
			.then((data: { authenticated?: boolean; user?: AuthUser | null } | null) => {
				if (!cancelled) setUser(data?.authenticated ? data.user ?? null : null);
			})
			.catch(() => {
				if (!cancelled) setUser(null);
			})
			.finally(() => {
				if (!cancelled) setLoading(false);
			});
		return () => {
			cancelled = true;
		};
	}, []);

	const login = (returnTo?: string) => {
		const target = returnTo ?? window.location.pathname;
		window.location.href = `/api/auth/login?returnTo=${encodeURIComponent(target)}`;
	};

	const logout = async () => {
		await fetch("/api/auth/logout", { method: "POST" });
		setUser(null);
	};

	return { user, loading, login, logout };
}
