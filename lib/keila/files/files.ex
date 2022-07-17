defmodule Keila.Files do
  @moduledoc """
  Module for handling images and other files uploaded by users.
  """

  @max_size 8_000_000

  use Keila.Repo
  alias Keila.Files.File
  alias __MODULE__.MediaType

  @spec store_file(Project.id(), Path.t(), term) :: term | {:error, term()}
  def store_file(project_id, source_path, metadata \\ []) do
    filename = get_filename(source_path, metadata)
    raw_type = Keyword.get(metadata, :type)

    with {:ok, size} <- get_and_validate_size(source_path),
         {:ok, type} <- get_and_validate_type(source_path, filename, raw_type) do
      uuid = Ecto.UUID.generate()
      sha256 = Keila.Hasher.hash_file(source_path, :sha256)
      adapter = get_default_adapter()

      metadata =
        metadata
        |> Keyword.put(:uuid, uuid)
        |> Keyword.put(:sha256, sha256)
        |> Keyword.put(:type, type)
        |> Keyword.put(:filename, filename)

      adapter_data = adapter.store(source_path, metadata)

      %{
        uuid: uuid,
        filename: filename,
        type: type,
        size: size,
        sha256: sha256,
        adapter: adapter.name(),
        adapter_data: adapter_data,
        project_id: project_id
      }
      |> File.creation_changeset()
      |> Repo.insert()
    end
  end

  defp get_filename(path, metadata) do
    Keyword.get_lazy(metadata, :filename, fn ->
      Path.basename(path) <> Path.extname(path)
    end)
  end

  defp get_and_validate_size(path) do
    %{size: size} = Elixir.File.stat!(path)

    if size <= @max_size do
      {:ok, size}
    else
      {:error, :too_large}
    end
  end

  defp get_and_validate_type(path, filename, raw_type) do
    with {:ok, filename_type} <- MediaType.type_from_filename(filename || path),
         {:ok, magic_number_type} <- MediaType.type_from_magic_number(path),
         {:ok, type} <- ensure_type_match(filename_type, magic_number_type, raw_type) do
      {:ok, type}
    else
      _ -> {:error, :type_mismatch}
    end
  end

  defp ensure_type_match(filename_type, magic_number_type, nil) do
    if MediaType.type_match?(filename_type, magic_number_type),
      do: {:ok, filename_type},
      else: :error
  end

  defp ensure_type_match(filename_type, magic_number_type, raw_type) do
    if raw_type == filename_type,
      do: ensure_type_match(filename_type, magic_number_type, nil),
      else: :error
  end

  @doc """
  Retrieves file from UUID.

  Returns `nil` if file doesn’t exist.
  """
  @spec get_file(File.id()) :: File.t() | nil
  def get_file(uuid) do
    Repo.get(File, uuid)
  end

  @doc """
  Retrieves the full URL of a file from its UUID.

  Returns `nil` if file doesn’t exist.
  """
  @spec get_file_url(File.id()) :: String.t() | nil
  def get_file_url(uuid) do
    case get_file(uuid) do
      nil ->
        nil

      file ->
        adapter = get_adapter(file.adapter)
        adapter.get_url(file)
    end
  end

  @doc """
  Deletes the file specified by its UUID.

  This function is idempotent and always returns `:ok`.
  """
  @spec delete_file(File.id()) :: :ok
  def delete_file(uuid) do
    case get_file(uuid) do
      nil ->
        :ok

      file ->
        adapter = get_adapter(file.adapter)
        adapter.delete(file)
    end
  end

  defp get_default_adapter() do
    Keyword.fetch!(Application.get_env(:keila, Keila.Files), :adapter)
  end

  defp get_adapter(name) do
    case name do
      "local" -> __MODULE__.StorageAdapters.Local
    end
  end
end
