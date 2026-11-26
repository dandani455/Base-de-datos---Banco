/** Correo de verificación por Resend. Con RESEND_ENABLED != 'true' no hace nada. */
export async function enviarVerificacion(to: string, link: string): Promise<void> {
  if (process.env.RESEND_ENABLED !== 'true') return;
  try {
    const { Resend } = await import('resend');
    await new Resend(process.env.RESEND_API_KEY).emails.send({
      from: process.env.MAIL_FROM ?? 'Banco Digital <onboarding@resend.dev>',
      to, subject: 'Verifica tu correo — Banco Digital',
      html: `<p>Bienvenido a Banco Digital.</p><p><a href="${link}">Verificar mi correo</a></p>`,
    });
  } catch (e) {
    // Un fallo del correo no debe romper el registro ya hecho.
    console.error('[resend]', (e as Error).message);
  }
}
