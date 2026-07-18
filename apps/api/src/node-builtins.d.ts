declare class Buffer extends Uint8Array {
  static from(value: string | Uint8Array, encoding?: string): Buffer;
  static isBuffer(value: unknown): value is Buffer;
  static concat(chunks: readonly Uint8Array[]): Buffer;
  readonly byteLength: number;
  toString(encoding?: string): string;
}

declare const process: {
  argv: string[];
  env: Record<string, string | undefined>;
  exitCode?: number;
};

declare const __filename: string;

declare module "node:crypto" {
  interface Hash {
    update(value: string | Uint8Array): Hash;
    digest(encoding: "hex"): string;
  }

  interface Hmac {
    update(value: string): Hmac;
    digest(): Buffer;
  }

  export function createHmac(algorithm: string, key: string | Uint8Array): Hmac;
  export function createHash(algorithm: string): Hash;
  export function randomBytes(size: number): Buffer;
  export function randomInt(min: number, max: number): number;
  export function randomUUID(): string;
  export function timingSafeEqual(left: Uint8Array, right: Uint8Array): boolean;
}

declare module "node:http" {
  interface Socket {
    remoteAddress?: string;
  }

  export interface IncomingMessage extends AsyncIterable<Uint8Array | string> {
    method?: string;
    url?: string;
    headers: {
      authorization?: string;
      "x-forwarded-for"?: string | string[];
      "x-pagepass-client-ip"?: string | string[];
    };
    socket: Socket;
  }

  export interface ServerResponse {
    writeHead(status: number, headers: Record<string, string>): void;
    end(body?: string): void;
  }

  export interface Server {
    once(event: "error", listener: (error: unknown) => void): this;
    listen(port: number, host: string, listener: () => void): this;
    close(callback?: (error?: Error) => void): this;
    address(): { port: number } | string | null;
  }

  export function createServer(
    listener: (request: IncomingMessage, response: ServerResponse) => void | Promise<void>
  ): Server;
}

declare module "node:net" {
  export function isIP(input: string): number;
}

declare module "node:path" {
  export function join(...paths: string[]): string;
  export function resolve(path: string): string;
}

declare module "node:fs" {
  export function readdirSync(path: string): string[];
  export function readFileSync(path: string, encoding: "utf8"): string;
}
