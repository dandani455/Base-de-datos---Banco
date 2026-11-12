import { Route, Routes } from 'react-router-dom';
import ErrorBanner from './components/ErrorBanner';
import Inicio from './pages/Inicio';
import Registro from './pages/Registro';
import Login from './pages/Login';
import ClienteLayout from './pages/cliente/Layout';
import Dashboard from './pages/cliente/Dashboard';
import Balance from './pages/cliente/Balance';
import Creditos from './pages/cliente/Creditos';
import Cdts from './pages/cliente/Cdts';
import Perfil from './pages/cliente/Perfil';
import AdminLayout from './pages/admin/Layout';
import Usuarios from './pages/admin/Usuarios';
import Operaciones from './pages/admin/Operaciones';
import Reloj from './pages/admin/Reloj';
import Tasas from './pages/admin/Tasas';
import Control from './pages/admin/Control';
import Demo from './pages/Demo';
import { DEMO } from './demo';

export default function App() {
  return (
    <>
      <ErrorBanner />
      <Routes>
        <Route path="/" element={<Inicio />} />
        <Route path="/registro" element={<Registro />} />
        <Route path="/login" element={<Login />} />
        {DEMO && <Route path="/demo" element={<Demo />} />}
        <Route path="/app" element={<ClienteLayout />}>
          <Route index element={<Dashboard />} />
          <Route path="balance" element={<Balance />} />
          <Route path="creditos" element={<Creditos />} />
          <Route path="cdts" element={<Cdts />} />
          <Route path="perfil" element={<Perfil />} />
        </Route>
        <Route path="/admin" element={<AdminLayout />}>
          <Route index element={<Usuarios />} />
          <Route path="operaciones" element={<Operaciones />} />
          <Route path="reloj" element={<Reloj />} />
          <Route path="tasas" element={<Tasas />} />
          <Route path="control" element={<Control />} />
        </Route>
        <Route path="*" element={<Inicio />} />
      </Routes>
    </>
  );
}
