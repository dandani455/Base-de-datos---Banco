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

export default function App() {
  return (
    <>
      <ErrorBanner />
      <Routes>
        <Route path="/" element={<Inicio />} />
        <Route path="/registro" element={<Registro />} />
        <Route path="/login" element={<Login />} />
        <Route path="/app" element={<ClienteLayout />}>
          <Route index element={<Dashboard />} />
          <Route path="balance" element={<Balance />} />
          <Route path="creditos" element={<Creditos />} />
          <Route path="cdts" element={<Cdts />} />
          <Route path="perfil" element={<Perfil />} />
        </Route>
        <Route path="*" element={<Inicio />} />
      </Routes>
    </>
  );
}
