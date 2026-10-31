import { useCallback, useEffect, useState } from 'react';
import { adminUsuarios, llamar, mensajeDe, supabase } from '../../lib/supabase';
import { useEnVivo } from '../../lib/vivo';
import { useAviso } from '../../componentes/Aviso';
import { PERFIL, fechaHora, type Usuario, type Yo } from '../../lib/tipos';

type Edicion = { id: string; tipo: 'nombre' | 'contrasena' | 'baja'; valor: string } | null;

// Solo los propietarios agregan, editan y dan de baja cuentas de meseros y cajeros.
export default function Usuarios({ yo }: { yo: Yo }) {
  const aviso = useAviso();
  const [usuarios, setUsuarios] = useState<Usuario[]>([]);
  const [nuevo, setNuevo] = useState({ usuario: '', nombre: '', perfil: 'mesero', contrasena: '' });
  const [edicion, setEdicion] = useState<Edicion>(null);
  const [ocupado, setOcupado] = useState(false);

  const cargar = useCallback(async () => {
    const { data } = await supabase.from('usuarios')
      .select('id, usuario, nombre, perfil, activo, baja_en, baja_motivo, creado_en')
      .order('activo', { ascending: false }).order('perfil').order('nombre');
    if (data) setUsuarios(data as Usuario[]);
  }, []);
  useEffect(() => { cargar(); }, [cargar]);
  useEnVivo(['usuarios'], cargar);

  async function hacer(fn: () => Promise<{ aviso?: string } | unknown>, exito: string) {
    setOcupado(true);
    try {
      const r = await fn();
      aviso((r as { aviso?: string })?.aviso ?? exito);
      return true;
    } catch (e) { aviso(mensajeDe(e)); return false; }
    finally { setOcupado(false); await cargar(); }
  }

  async function crear(e: React.FormEvent) {
    e.preventDefault();
    if (await hacer(() => adminUsuarios({ accion: 'crear', ...nuevo }),
      `Cuenta creada. ${nuevo.nombre.trim()} entra con el usuario "${nuevo.usuario.trim().toLowerCase()}".`)) {
      setNuevo({ usuario: '', nombre: '', perfil: nuevo.perfil, contrasena: '' });
    }
  }

  async function guardarEdicion(u: Usuario) {
    if (!edicion) return;
    let ok = false;
    if (edicion.tipo === 'nombre') ok = await hacer(() => llamar('renombrar_usuario', { p_id: u.id, p_nombre: edicion.valor }), 'Nombre actualizado');
    if (edicion.tipo === 'contrasena') ok = await hacer(() => adminUsuarios({ accion: 'cambiar_contrasena', id: u.id, contrasena: edicion.valor }), 'Contraseña actualizada');
    if (edicion.tipo === 'baja') ok = await hacer(() => adminUsuarios({ accion: 'dar_de_baja', id: u.id, motivo: edicion.valor }),
      `${u.nombre} quedó dado de baja. Ya no puede entrar; su historial se conserva.`);
    if (ok) setEdicion(null);
  }

  const etiqueta = { nombre: 'Nuevo nombre', contrasena: 'Contraseña nueva (mínimo 8)', baja: 'Motivo de la baja (obligatorio)' };

  return (
    <>
      <div className="box">
        <h2>Agregar mesero o cajero</h2>
        <form className="f" onSubmit={crear}>
          <input placeholder="Nombre (ej. Carlos Pérez)" value={nuevo.nombre} aria-label="Nombre"
                 onChange={(e) => setNuevo({ ...nuevo, nombre: e.target.value })} />
          <input placeholder="Usuario para entrar (ej. carlos)" value={nuevo.usuario} aria-label="Usuario" autoCapitalize="none"
                 onChange={(e) => setNuevo({ ...nuevo, usuario: e.target.value })} />
          <select value={nuevo.perfil} onChange={(e) => setNuevo({ ...nuevo, perfil: e.target.value })} aria-label="Perfil">
            <option value="mesero">Mesero</option><option value="cajero">Cajero</option>
          </select>
          <input type="password" placeholder="Contraseña inicial (mínimo 8)" autoComplete="new-password" value={nuevo.contrasena}
                 aria-label="Contraseña inicial" onChange={(e) => setNuevo({ ...nuevo, contrasena: e.target.value })} />
          <button className="btn" disabled={ocupado || !nuevo.nombre.trim() || !nuevo.usuario.trim() || nuevo.contrasena.length < 8}>Agregar</button>
        </form>
        <p className="note">El usuario es lo que escribirá para entrar: minúsculas, sin espacios. Dale la contraseña en persona.</p>
      </div>

      <div className="box">
        <h2>Usuarios</h2>
        {usuarios.map((u) => {
          const esOtroPropietario = u.perfil === 'propietario' && u.id !== yo.id;
          return (
            <div key={u.id}>
              <div className="row">
                <span className="n">
                  <b>{u.nombre}</b>{u.id === yo.id && ' (tú)'}
                  <small>{PERFIL[u.perfil]} · usuario: {u.usuario}{!u.activo && u.baja_en ? ` · baja el ${fechaHora(u.baja_en)}: ${u.baja_motivo}` : ''}</small>
                </span>
                <span className={`chip ${u.activo ? 'g' : 'r'}`}>{u.activo ? 'Activo' : 'De baja'}</span>
                <button className="btn s" disabled={ocupado} onClick={() => setEdicion({ id: u.id, tipo: 'nombre', valor: u.nombre })}>Renombrar</button>
                {u.perfil !== 'propietario' && u.activo && (
                  <button className="btn s" disabled={ocupado}
                          onClick={() => hacer(() => llamar('cambiar_perfil_usuario', { p_id: u.id, p_perfil: u.perfil === 'mesero' ? 'cajero' : 'mesero' }),
                            `${u.nombre} ahora es ${u.perfil === 'mesero' ? 'cajero' : 'mesero'}`)}>
                    Cambiar a {u.perfil === 'mesero' ? 'cajero' : 'mesero'}
                  </button>
                )}
                {!esOtroPropietario && u.activo && (
                  <button className="btn s" disabled={ocupado} onClick={() => setEdicion({ id: u.id, tipo: 'contrasena', valor: '' })}>Cambiar contraseña</button>
                )}
                {u.perfil !== 'propietario' && (u.activo
                  ? <button className="btn d" disabled={ocupado} onClick={() => setEdicion({ id: u.id, tipo: 'baja', valor: '' })}>Dar de baja</button>
                  : <button className="btn s" disabled={ocupado}
                            onClick={() => hacer(() => adminUsuarios({ accion: 'reactivar', id: u.id }), `${u.nombre} reactivado`)}>Reactivar</button>)}
              </div>
              {edicion?.id === u.id && (
                <form className="f" style={{ padding: '0 0 10px' }} onSubmit={(e) => { e.preventDefault(); guardarEdicion(u); }}>
                  <input autoFocus type={edicion.tipo === 'contrasena' ? 'password' : 'text'} autoComplete={edicion.tipo === 'contrasena' ? 'new-password' : 'off'}
                         placeholder={etiqueta[edicion.tipo]} aria-label={etiqueta[edicion.tipo]} value={edicion.valor}
                         onChange={(e) => setEdicion({ ...edicion, valor: e.target.value })} />
                  <button className={edicion.tipo === 'baja' ? 'btn d' : 'btn'}
                          disabled={ocupado || !edicion.valor.trim() || (edicion.tipo === 'contrasena' && edicion.valor.length < 8)}>
                    {edicion.tipo === 'baja' ? 'Confirmar baja' : 'Guardar'}
                  </button>
                  <button type="button" className="btn s" onClick={() => setEdicion(null)}>Cancelar</button>
                </form>
              )}
            </div>
          );
        })}
        <p className="note">
          Dar de baja cierra su acceso de inmediato y conserva todo su historial; la cuenta no se borra.
          Cada propietario cambia solo su propia contraseña.
        </p>
      </div>
    </>
  );
}
