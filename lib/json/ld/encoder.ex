defmodule JSON.LD.Encoder do
  @moduledoc """
  """

  use RDF.Serialization.Encoder

  alias RDF.{IRI, BlankNode, Literal}
  alias RDF.NS.{XSD}

  @rdf_type  to_string(RDF.NS.RDF.type)
  @rdf_nil   to_string(RDF.NS.RDF.nil)
  @rdf_first to_string(RDF.NS.RDF.first)
  @rdf_rest  to_string(RDF.NS.RDF.rest)
  @rdf_list  to_string(RDF.uri(RDF.NS.RDF.List))

  def encode(data, opts \\ []) do
    with {:ok, json_ld_object} <- from_rdf(data, opts) do
      encode_json(json_ld_object)
    end
  end

  def encode!(data, opts \\ []) do
    data
    |> from_rdf!(opts)
    |> encode_json!
  end

  def from_rdf(dataset, options \\ %JSON.LD.Options{}) do
    try do
      {:ok, from_rdf!(dataset, options)}
    rescue
      exception -> {:error, Exception.message(exception)}
    end
  end

  def from_rdf!(dataset, options \\ %JSON.LD.Options{}) do
    with options = JSON.LD.Options.new(options) do
      graph_map =
        Enum.reduce RDF.Dataset.graphs(dataset), %{},
          fn graph, graph_map ->
            # 3.1)
            name = to_string(graph.name || "@default")

            # 3.3)
            graph_map =
              if graph.name && !get_in(graph_map, ["@default", name]) do
                Map.update graph_map, "@default", %{name => %{"@id" => name}},
                  fn default_graph ->
                    Map.put(default_graph, name, %{"@id" => name})
                  end
              else
                graph_map
              end

            # 3.2 + 3.4)
            Map.put(graph_map, name,
              node_map_from_graph(graph, Map.get(graph_map, name, %{}),
                options.use_native_types, options.use_rdf_type))
          end

      # 4)
      graph_map =
        Enum.reduce graph_map, %{}, fn ({name, graph_object}, graph_map) ->
          Map.put(graph_map, name, convert_list(graph_object))
        end

      # 5+6)
      Map.get(graph_map, "@default", %{})
      |> Enum.sort_by(fn {subject, _} -> subject end)
      |> Enum.reduce([], fn ({subject, node}, result) ->
           # 6.1)
           node =
             if Map.has_key?(graph_map, subject) do
               Map.put node, "@graph",
                 graph_map[subject]
                 |> Enum.sort_by(fn {s, _} -> s end)
                 |> Enum.reduce([], fn ({_s, n}, graph_nodes) ->
                      n = Map.delete(n, "usages")
                      if Map.size(n) == 1 and Map.has_key?(n, "@id") do
                        graph_nodes
                      else
                        [n | graph_nodes]
                      end
                    end)
                 |> Enum.reverse
             else
               node
             end

           # 6.2)
           node = Map.delete(node, "usages")
           if Map.size(node) == 1 and Map.has_key?(node, "@id") do
             result
           else
             [node | result]
           end
         end)
      |> Enum.reverse
    end
  end

  # 3.5)
  defp node_map_from_graph(graph, current, use_native_types, use_rdf_type) do
    Enum.reduce(graph, current, fn ({subject, predicate, object}, node_map) ->
      {subject, predicate, node_object} =
        {to_string(subject), to_string(predicate), nil}
      node = Map.get(node_map, subject, %{"@id" => subject})
      {node_object, node_map} =
        if is_node_object = (match?(%IRI{}, object) || match?(%BlankNode{}, object)) do
          node_object = to_string(object)
          node_map = Map.put_new(node_map, node_object, %{"@id" => node_object})
          {node_object, node_map}
        else
          {node_object, node_map}
        end
      {node, node_map} =
        if is_node_object and !use_rdf_type and predicate == @rdf_type do
          node = Map.update(node, "@type", [node_object], fn types ->
            if node_object in types do
              types
            else
              types ++ [node_object]
            end
          end)
          {node, node_map}
        else
          value = rdf_to_object(object, use_native_types)
          node =
            Map.update(node, predicate, [value], fn objects ->
              if value in objects do
                objects
              else
                objects ++ [value]
              end
            end)
          node_map =
            if is_node_object do
              usage = %{
                "node"        => node,
                "property"    => predicate,
                "value"       => value,
              }
              Map.update(node_map, node_object, %{"usages" => [usage]}, fn object_node ->
                Map.update(object_node, "usages", [usage], fn usages ->
                  usages ++ [usage]
                end)
              end)
            else
              node_map
            end
          {node, node_map}
        end
      Map.put(node_map, subject, node)
    end)
    |> update_node_usages
  end

  # This function is necessary because we have no references and must update the
  # node member of the usage maps with later enhanced usages
  defp update_node_usages(node_map) do
    Enum.reduce node_map, node_map, fn
      ({subject, %{"usages" => _usages} = _node}, node_map) ->
        update_in node_map, [subject, "usages"], fn usages ->
          Enum.map usages, fn usage ->
            Map.update! usage, "node", fn %{"@id" => subject} ->
              node_map[subject]
            end
          end
        end
      (_, node_map) -> node_map
    end
  end

  # This function is necessary because we have no references and use this
  # instead to update the head by path
  defp update_head(graph_object, path, old, new) do
    update_in graph_object, path, fn objects ->
      Enum.map objects, fn
        ^old    -> new
        current -> current
      end
    end
  end

  # 4)
  defp convert_list(%{@rdf_nil => nil_node} = graph_object) do
    Enum.reduce nil_node["usages"], graph_object,
      # 4.3.1)
      fn (usage, graph_object) ->
        # 4.3.2) + 4.3.3)
        {list, list_nodes, [subject, property] = head_path, head} =
          extract_list(usage)

        # 4.3.4)
        {skip, list, list_nodes, head_path, head} =
          if property == @rdf_first do
            # 4.3.4.1)
            if subject == @rdf_nil do
              {true, list, list_nodes, head_path, head}
            else
              # 4.3.4.3-5)
              head_path = [head["@id"], @rdf_rest]
              head = List.first(graph_object[head["@id"]][@rdf_rest])
              # 4.3.4.6)
              [_ | list] = list
              [_ | list_nodes] = list_nodes
              {false, list, list_nodes, head_path, head}
            end
          else
            {false, list, list_nodes, head_path, head}
          end
        if skip do
          graph_object
        else
          graph_object =
            update_head graph_object, head_path, head,
              head
              # 4.3.5)
              |> Map.delete("@id")
              # 4.3.6) isn't necessary, since we built the list in reverse order
              # 4.3.7)
              |> Map.put("@list", list)

          # 4.3.8)
          Enum.reduce(list_nodes, graph_object, fn (node_id, graph_object) ->
            Map.delete(graph_object, node_id)
          end)
        end
      end
  end

  defp convert_list(graph_object), do: graph_object


  # 4.3.3)
  defp extract_list(usage, list \\ [], list_nodes \\ [])

  defp extract_list(
    %{"node" => %{
         # Spec FIXME: no mention of @id
         "@id"       => id = ("_:" <> _), # contrary to spec we assume/require this to be even on the initial call to be a blank node
         "usages"    => [usage],
         @rdf_first  => [first],
         @rdf_rest   => [_rest],
         } = node,
      "property" => @rdf_rest}, list, list_nodes) when map_size(node) == 4 do
    extract_list(usage, [first | list], [id | list_nodes])
  end

  defp extract_list(
    %{"node" => %{
         # Spec FIXME: no mention of @id
         "@id"       => id = ("_:" <> _), # contrary to spec we assume/require this to be even on the initial call to be a blank node
         "@type"     => [@rdf_list],
         "usages"    => [usage],
         @rdf_first  => [first],
         @rdf_rest   => [_rest],
         } = node,
      "property" => @rdf_rest}, list, list_nodes) when map_size(node) == 5 do
    extract_list(usage, [first | list], [id | list_nodes])
  end

  defp extract_list(%{"node" => %{"@id" => subject}, "property" => property, "value" => head},
        list, list_nodes),
    do: {list, list_nodes, [subject, property], head}


  defp rdf_to_object(%IRI{} = iri, _use_native_types) do
    %{"@id" => to_string(iri)}
  end

  defp rdf_to_object(%BlankNode{} = bnode, _use_native_types) do
    %{"@id" => to_string(bnode)}
  end

  defp rdf_to_object(%Literal{value: value, datatype: datatype} = literal, use_native_types) do
    result = %{}
    converted_value = literal
    type = nil
    {converted_value, type, result} =
      if use_native_types do
        cond do
          datatype == XSD.string ->
            {value, type, result}
          datatype == XSD.boolean ->
            if RDF.Boolean.valid?(literal) do
              {value, type, result}
            else
              {converted_value, XSD.boolean, result}
            end
          datatype in [XSD.integer, XSD.double] ->
            if RDF.Literal.valid?(literal) do
              {value, type, result}
            else
              {converted_value, type, result}
            end
          true ->
            {converted_value, datatype, result}
        end
      else
        cond do
          datatype == RDF.langString ->
            {converted_value, type, Map.put(result, "@language", literal.language)}
          datatype == XSD.string ->
            {converted_value, type, result}
          true ->
            {converted_value, datatype, result}
        end
      end

    result = type && Map.put(result, "@type", to_string(type)) || result
    Map.put(result, "@value",
      match?(%Literal{}, converted_value) && Literal.lexical(converted_value) || converted_value)
  end


  # TODO: This should not be dependent on Poison as a JSON encoder in general,
  #   but determine available JSON encoders and use one heuristically or by configuration
  defp encode_json(value, opts \\ []) do
    Poison.encode(value)
  end

  defp encode_json!(value, opts \\ []) do
    Poison.encode!(value)
  end

end
