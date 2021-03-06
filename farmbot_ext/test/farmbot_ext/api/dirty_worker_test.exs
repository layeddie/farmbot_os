defmodule FarmbotExt.API.DirtyWorkerTest do
  require Helpers

  use ExUnit.Case
  use Mimic

  alias FarmbotCore.Asset.{
    FbosConfig,
    Point,
    Private,
    Private.LocalMeta,
    Repo
  }

  alias FarmbotExt.API.DirtyWorker

  setup :verify_on_exit!

  test "child spec" do
    spec = DirtyWorker.child_spec(Point)
    assert spec[:id] == {DirtyWorker, Point}
    assert spec[:start] == {DirtyWorker, :start_link, [[module: Point, timeout: 1000]]}
    assert spec[:type] == :worker
    assert spec[:restart] == :permanent
    assert spec[:shutdown] == 500
  end

  test "maybe_resync runs when there is stale data" do
    Helpers.delete_all_points()
    p = Helpers.create_point(%{id: 1, pointer_type: "Plant"})
    Private.mark_stale!(p)
    assert Private.any_stale?()

    expect(FarmbotCeleryScript.SysCalls, :sync, 1, fn ->
      Private.mark_clean!(p)
    end)

    DirtyWorker.maybe_resync(0)
  end

  test "handle_http_response - 409 response" do
    Helpers.delete_all_points()
    Repo.delete_all(LocalMeta)
    Repo.delete_all(FbosConfig)

    conf =
      FarmbotCore.Asset.fbos_config()
      |> FbosConfig.changeset()
      |> Repo.insert!()

    expect(FarmbotCeleryScript.SysCalls, :sync, 1, fn ->
      "I expect a 409 response to trigger a sync."
    end)

    expect(Private, :recover_from_row_lock_failure, 1, fn ->
      "I expect a 409 response to trigger a row lock failure recovery."
    end)

    DirtyWorker.handle_http_response(conf, FbosConfig, {:ok, %{status: 409}})
  end

  test "maybe_resync does not run when there is *NOT* stale data" do
    Helpers.delete_all_points()
    Repo.delete_all(LocalMeta)

    stub(FarmbotCeleryScript.SysCalls, :sync, fn ->
      flunk("Never should call sync")
    end)

    refute(Private.any_stale?())
    refute(DirtyWorker.maybe_resync(0))
  end

  test "race condition detector: has_race_condition?(module, list)" do
    Helpers.delete_all_points()
    Repo.delete_all(LocalMeta)
    ok = Helpers.create_point(%{id: 1})
    no = Map.merge(ok, %{pullout_direction: 0})
    refute DirtyWorker.has_race_condition?(Point, [ok])
    assert DirtyWorker.has_race_condition?(Point, [no])
    refute DirtyWorker.has_race_condition?(Point, [])
  end

  test "finalize/2" do
    stub_data = %{valid?: true, anything: :rand.uniform(100)}

    expect(Repo, :update!, 1, fn data ->
      assert data == stub_data
      data
    end)

    expect(Private, :mark_clean!, 1, fn data ->
      assert data == stub_data
      data
    end)

    assert :ok == DirtyWorker.finalize(stub_data, Point)
  end

  # This test blinks too much:
  #
  # test "init" do
  #   Helpers.delete_all_points()
  #   Helpers.use_fake_jwt()
  #   {:ok, pid} = DirtyWorker.start_link(module: Point, timeout: 0)
  #   state = :sys.get_state(pid)
  #   assert state == %{module: Point}
  #   Helpers.wait_for(pid)
  #   GenServer.stop(pid, :normal)
  # end

  # This test blinks too much:
  #
  # test "work/2 error" do
  #   Helpers.delete_all_points()
  #   Helpers.use_fake_jwt()
  #   %mod{} = p = Helpers.create_point(%{id: 0, pointer_type: "Plant"})
  #   {:error, _} = DirtyWorker.work(p, mod)
  # end
end
