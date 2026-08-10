import { Resend } from "resend";

export interface EmailMessage {
  to: string | string[];
  subject: string;
  text: string;
  html?: string;
}

export type SendEmail = (message: EmailMessage) => Promise<void>;

export function createEmailSender(input: {
  apiKey?: string;
  from: string;
  environment: "development" | "test" | "production";
  log?: (message: string) => void;
}): SendEmail {
  const client = input.apiKey === undefined ? undefined : new Resend(input.apiKey);
  const log = input.log ?? console.log;

  return async (message) => {
    if (client === undefined) {
      if (input.environment === "production") {
        throw new Error("Resend is not configured");
      }
      log(`[dev email] to=${String(message.to)} subject="${message.subject}"\n${message.text}`);
      return;
    }

    const result = await client.emails.send({
      from: input.from,
      ...message
    });
    if (result.error !== null) {
      throw new Error(`Resend send failed: ${result.error.message}`);
    }
  };
}
