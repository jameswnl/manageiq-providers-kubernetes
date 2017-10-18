module ManageIQ
  module Providers
    module Kubernetes
      module ContainerManager::RefresherMixin
        def preprocess_targets
          @targets_by_ems_id.each do |ems_id, targets|
            # We want all targets of class EmsEvent to be merged into one target, so they can be refreshed together, otherwise
            # we could be missing some crosslinks in the refreshed data
            ems_targets, sub_ems_targets = targets.partition { |x| x.kind_of?(ExtManagementSystem) }
            all_targets = []

            if sub_ems_targets.present?
              # We can disable targeted refresh with a setting, then we will just do full ems refresh on any event
              ems_event_collection = ManagerRefresh::TargetCollection.new(:targets    => sub_ems_targets,
                                                                          :manager_id => ems_id)
              # Before full EMS refresh, we want to refresh any targets found
              all_targets << ems_event_collection
            end

            if ems_targets.present?
              # There should be only 1 ems
              all_targets << ems_targets.first
            end

            @targets_by_ems_id[ems_id] = all_targets
          end
        end

        def collect_inventory_for_targets(ems, targets)
          # TODO (lsmola) we need to move to common Graph Refresh architecture with Inventory Builder having Collector,
          # Parser and Persister
          targets.map do |target|
            inventory = if target.kind_of?(ManagerRefresh::TargetCollection)
                          target_collection_collector_class.new(ems, target).inventory(all_entities)
                        else
                          collect_full_inventory(ems)
                        end
            EmsRefresh.log_inv_debug_trace(inventory, "inv_hash:")
            [target, inventory]
          end
        end

        def parse_targeted_inventory(ems, target, inventory)
          # TODO (lsmola) we need to move to common Graph Refresh architecture with Inventory Builder having Collector,
          # Parser and Persister
          if refresher_options.inventory_object_refresh
            if target.kind_of?(ManagerRefresh::TargetCollection)
              refresh_parser_class.target_collection_inv_to_persister(ems, inventory, refresher_options)
            else
              refresh_parser_class.ems_inv_to_persister(ems, inventory, refresher_options)
            end
          else
            refresh_parser_class.ems_inv_to_hashes(inventory, refresher_options)
          end
        end

        KUBERNETES_ENTITIES = [
          {:name => 'pods'}, {:name => 'services'}, {:name => 'replication_controllers'}, {:name => 'nodes'},
          {:name => 'endpoints'}, {:name => 'namespaces'}, {:name => 'resource_quotas'}, {:name => 'limit_ranges'},
          {:name => 'persistent_volumes'}, {:name => 'persistent_volume_claims'}
        ]

        def fetch_entities(client, entities)
          entities.each_with_object({}) do |entity, h|
            begin
              h[entity[:name].singularize] = client.send("get_#{entity[:name]}")
            rescue KubeException => e
              raise e if entity[:default].nil?
              $log.warn("Unexpected Exception during refresh: #{e}")
              h[entity[:name].singularize] = entity[:default]
            end
          end
        end

        def manager_refresh_post_processing(_ems, _target, inventory_collections)
          indexed = inventory_collections.index_by(&:name)
          container_images_post_processing(indexed[:container_images])
        end

        def container_images_post_processing(container_images)
          # We want this post processing job only for batches, for the rest it's after_create hook on the Model
          return unless container_images.saver_strategy == :batch

          # TODO extract the batch size to Settings
          batch_size = 100
          container_images.created_records.each_slice(batch_size) do |batch|
            container_images_ids = batch.collect { |x| x[:id] }
            MiqQueue.submit_job(
              :class_name  => "ContainerImage",
              :method_name => 'raise_creation_events',
              :args        => [container_images_ids],
              :priority    => MiqQueue::HIGH_PRIORITY
            )
          end
        end
      end
    end
  end
end
