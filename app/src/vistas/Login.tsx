import { useState, type FormEvent } from 'react';
import { correoDe, mensajeDe, supabase } from '../lib/supabase';

export default function Login() {
  const [usuario, setUsuario] = useState('');
  const [contrasena, setContrasena] = useState('');
  const [error, setError] = useState('');
  const [enviando, setEnviando] = useState(false);

  async function entrar(e: FormEvent) {
    e.preventDefault();
    setError('');
    setEnviando(true);
    const { error } = await supabase.auth.signInWithPassword({ email: correoDe(usuario), password: contrasena });
    setEnviando(false);
    if (error) setError(mensajeDe(error));
  }

  return (
    <form className="login" onSubmit={entrar}>
      <div className="marca">
        <img src="/icono-192.png" alt="" />
        <h1>La Merced</h1>
      </div>
      {error && <p className="lock er" role="alert">{error}</p>}
      <label htmlFor="usuario">Usuario</label>
      <input id="usuario" autoComplete="username" autoCapitalize="none" spellCheck={false}
             value={usuario} onChange={(e) => setUsuario(e.target.value)} required />
      <label htmlFor="contrasena">Contraseña</label>
      <input id="contrasena" type="password" autoComplete="current-password"
             value={contrasena} onChange={(e) => setContrasena(e.target.value)} required />
      <button className="cta" disabled={enviando}>{enviando ? 'Entrando…' : 'Entrar'}</button>
    </form>
  );
}
