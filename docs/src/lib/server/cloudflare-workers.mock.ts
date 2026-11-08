declare const process: { env: Record<string, string | undefined> };

export const env = process.env;
