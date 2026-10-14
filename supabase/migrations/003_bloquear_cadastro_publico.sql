-- Ninguém se cadastra sozinho pela API: contas de bar são criadas só pela plataforma.
-- Para liberar um cadastro pontual via admin: set dnbar.allow_signup = 'on' na sessão.
create or replace function public.block_public_signup() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
  if session_user = 'supabase_auth_admin' and coalesce(current_setting('dnbar.allow_signup', true), '') <> 'on' then
    raise exception 'Cadastro desativado';
  end if;
  return new;
end $$;
revoke execute on function public.block_public_signup() from public, anon, authenticated;
grant execute on function public.block_public_signup() to supabase_auth_admin;
create trigger block_public_signup before insert on auth.users for each row execute function public.block_public_signup();
